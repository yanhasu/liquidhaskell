{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FlexibleContexts       #-} 
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE EmptyDataDecls         #-}

module Language.Haskell.Liquid.CoreToLogic ( 

  coreToDef , coreToFun
  , mkLit, runToLogic,
  logicType, 
  strengthenResult

  ) where

import GHC hiding (Located)
import Var
import Type 

import qualified CoreSyn   as C
import Literal
import IdInfo


import TysWiredIn

import Control.Applicative 

import Language.Fixpoint.Misc
import Language.Fixpoint.Names (dropModuleNames, isPrefixOfSym)
import Language.Fixpoint.Types hiding (Def, R, simplify)
import qualified Language.Fixpoint.Types as F
import Language.Haskell.Liquid.GhcMisc
import Language.Haskell.Liquid.GhcPlay
import Language.Haskell.Liquid.Types    hiding (GhcInfo(..), GhcSpec (..))
import Language.Haskell.Liquid.WiredIn
import Language.Haskell.Liquid.RefType



import qualified Data.HashMap.Strict as M

import Data.Monoid


logicType :: (Reftable r) => Type -> RRType r
logicType τ = fromRTypeRep $ t{ty_res = res, ty_binds = binds, ty_args = args}
  where 
    t   = toRTypeRep $ ofType τ 
    res = mkResType $ ty_res t
    (binds, args) =  unzip $ dropWhile isClassBind $ zip (ty_binds t) (ty_args t)
    

    mkResType t 
     | isBool t   = propType
     | otherwise  = t

isBool (RApp (RTyCon{rtc_tc = c}) _ _ _) = c == boolTyCon
isBool _ = False

isClassBind   = isClassType . snd

{- strengthenResult type: the refinement depends on whether the result type is a Bool or not:

CASE1: measure f@logic :: X -> Prop <=> f@haskell :: x:X -> {v:Bool | (Prop v) <=> (f@logic x)} 

CASE2: measure f@logic :: X -> Y    <=> f@haskell :: x:X -> {v:Y    | v = (f@logic x)} 
-}

strengthenResult :: Var -> SpecType
strengthenResult v
  | isBool res
  = -- traceShow ("Type for " ++ showPpr v ++ "\t OF \t" ++ show (ty_binds rep)) $  
    fromRTypeRep $ rep{ty_res = res `strengthen` r, ty_binds = xs}
  | otherwise
  = -- traceShow ("Type for " ++ showPpr v ++ "\t OF \t" ++ show (ty_binds rep)) $ 
    fromRTypeRep $ rep{ty_res = res `strengthen` r', ty_binds = xs}
  where rep = toRTypeRep t
        res = ty_res rep
        xs  = intSymbol (symbol ("x" :: String)) <$> [1..]
        r'  = U (exprReft (EApp f (EVar <$> vxs)))         mempty mempty
        r   = U (propReft (PBexp $ EApp f (EVar <$> vxs))) mempty mempty
        vxs = fst $  unzip $ dropWhile isClassBind $ zip xs (ty_args rep)
        f   = dummyLoc $ dropModuleNames $ simplesymbol v
        t   = (ofType $ varType v) :: SpecType


simplesymbol = symbol . getName

newtype LogicM a = LM {runM :: LState -> Either a Error}

data LState = LState { symbolMap :: LogicMap 
                     , mkError   :: String -> Error
                     }


instance Monad LogicM where
  return = LM . const . Left
  (LM m) >>= f 
    = LM $ \s -> case m s of 
                (Left x) -> (runM (f x)) s 
                (Right x) -> Right x

instance Functor LogicM where
  fmap f (LM m) = LM $ \s -> case m s of 
                              (Left  x) -> Left $ f x
                              (Right x) -> Right x

instance Applicative LogicM where
  pure = LM . const . Left
  (LM f) <*> (LM m) 
    = LM $ \s -> case (f s, m s) of 
                  (Left f , Left x ) -> Left $ f x
                  (Right f, Left _ ) -> Right f
                  (Left _ , Right x) -> Right x
                  (Right _, Right x) -> Right x

throw :: String -> LogicM a
throw str = LM $ \s -> Right $ (mkError s) str

getState :: LogicM LState
getState = LM $ Left 

runToLogic lmap ferror (LM m) 
  = m $ LState {symbolMap = lmap, mkError = ferror}

coreToDef :: LocSymbol -> Var -> C.CoreExpr ->  LogicM [Def DataCon]
coreToDef x _ e = go $ inline_preds $ simplify e
  where
    go (C.Lam _  e) = go e
    go (C.Tick _ e) = go e
    go (C.Case _ _ t alts) 
      | eqType t boolTy = mapM goalt_prop alts
      | otherwise       = mapM goalt      alts
    go _                = throw "Measure Functions should have a case at top level"

    goalt ((C.DataAlt d), xs, e)      = ((Def x d (symbol <$> xs)) . E) <$> coreToLogic e
    goalt alt = throw $ "Bad alternative" ++ showPpr alt

    goalt_prop ((C.DataAlt d), xs, e) = ((Def x d (symbol <$> xs)) . P) <$> coreToPred  e
    goalt_prop alt = throw $ "Bad alternative" ++ showPpr alt

    inline_preds = inline (eqType boolTy . varType)

coreToFun :: LocSymbol -> Var -> C.CoreExpr ->  LogicM ([Symbol], Either Pred Expr)
coreToFun _ v e = go [] $ inline_preds $ simplify e
  where
    go acc (C.Lam x e)  | isTyVar    x = go acc e
    go acc (C.Lam x e)  | isErasable x = go acc e
    go acc (C.Lam x e)  = go (symbol x : acc) e
    go acc (C.Tick _ e) = go acc e
    go acc e            | eqType rty boolTy 
                        = (reverse acc,) . Left  . traceShow "coreToPred"  <$> coreToPred e  
                        | otherwise       
                        = (reverse acc,) . Right . traceShow "coreToLogic" <$> coreToLogic e

    inline_preds = inline (eqType boolTy . varType)

    rty = snd $ splitFunTys $ snd $ splitForAllTys $ varType v

instance Show C.CoreExpr where
  show = showPpr

coreToPred :: C.CoreExpr -> LogicM Pred
coreToPred (C.Let b p)  = subst1 <$> coreToPred p <*>  makesub b
coreToPred (C.Tick _ p) = coreToPred p
coreToPred (C.App (C.Var v) e) | ignoreVar v = coreToPred e
coreToPred (C.Var x)
  | x == falseDataConId
  = return PFalse
  | x == trueDataConId
  = return PTrue
coreToPred p@(C.App _ _) = toPredApp p  
coreToPred e
  = PBexp <$> coreToLogic e  
-- coreToPred e                  
--  = throw ("Cannot transform to Logical Predicate:\t" ++ showPpr e)


coreToLogic :: C.CoreExpr -> LogicM Expr
coreToLogic (C.Let b e)  = subst1 <$> coreToLogic e <*>  makesub b
coreToLogic (C.Tick _ e) = coreToLogic e
coreToLogic (C.App (C.Var v) e) | ignoreVar v = coreToLogic e
coreToLogic (C.Lit l)            
  = case mkLit l of 
     Nothing -> throw $ "Bad Literal in measure definition" ++ showPpr l
     Just i -> return i
coreToLogic (C.Var x)           = (symbolMap <$> getState) >>= eVarWithMap x
coreToLogic e@(C.App _ _)       = toLogicApp e 
coreToLogic (C.Case e b _ alts) | eqType (varType b) boolTy
  = checkBoolAlts alts >>= coreToIte e 
coreToLogic e                   = throw ("Cannot transform to Logic:\t" ++ showPpr e)

checkBoolAlts :: [C.CoreAlt] -> LogicM (C.CoreExpr, C.CoreExpr)
checkBoolAlts [(C.DataAlt false, [], efalse), (C.DataAlt true, [], etrue)]
  | false == falseDataCon, true == trueDataCon
  = return (efalse, etrue)
checkBoolAlts [(C.DataAlt true, [], etrue), (C.DataAlt false, [], efalse)]
  | false == falseDataCon, true == trueDataCon
  = return (efalse, etrue)
checkBoolAlts alts
  = throw ("checkBoolAlts failed on " ++ showPpr alts)  

coreToIte e (efalse, etrue)
  = do p  <- coreToPred e
       e1 <- coreToLogic efalse 
       e2 <- coreToLogic etrue
       return $ EIte p e2 e1

toPredApp :: C.CoreExpr -> LogicM Pred
toPredApp p 
  = do let (f, es) = splitArgs p
       f'         <- tosymbol f
       go f' es
  where
    go f [e1, e2]
      | Just rel <- M.lookup (val f) brels 
      = PAtom rel <$> (coreToLogic e1) <*> (coreToLogic e2)
    go f [e]
      | val f == symbol ("not" :: String)
      = PNot <$>  coreToPred e
    go f [e1, e2]
      | val f == symbol ("||" :: String)
      = POr <$> mapM coreToPred [e1, e2]
      | val f == symbol ("&&" :: String)
      = PAnd <$> mapM coreToPred [e1, e2]
    go f es
      | val f == symbol ("or" :: String)
      = POr <$> mapM coreToPred es
      | val f == symbol ("and" :: String)
      = PAnd <$> mapM coreToPred es
      | otherwise
      = PBexp <$> toLogicApp p

toLogicApp :: C.CoreExpr -> LogicM Expr
toLogicApp e   
  =  do let (f, es) = splitArgs e
        args       <- mapM coreToLogic es
        lmap       <- symbolMap <$> getState
        def         <- (`EApp` args) <$> tosymbol f
        (\x -> makeApp def lmap x args) <$> tosymbol' f

makeApp :: Expr -> LogicMap -> Located Symbol-> [Expr] -> Expr
makeApp _ _ f [e1, e2] | Just op <- M.lookup (val f) bops
  = EBin op e1 e2

makeApp def lmap f es 
  = eAppWithMap lmap f es def

eVarWithMap :: Id -> LogicMap -> LogicM Expr
eVarWithMap x lmap 
  = do f' <- tosymbol' (C.Var x :: C.CoreExpr)
       return $ eAppWithMap lmap f' [] (EVar $ symbol x)

brels :: M.HashMap Symbol Brel
brels = M.fromList [ (symbol ("==" :: String), Eq)
                   , (symbol ("/=" :: String), Ne)
                   , (symbol (">=" :: String), Ge)
                   , (symbol (">" :: String) , Gt)
                   , (symbol ("<=" :: String), Le)
                   , (symbol ("<" :: String) , Lt)
                   ]

bops :: M.HashMap Symbol Bop
bops = M.fromList [ (numSymbol "+", Plus)
                  , (numSymbol "-", Minus)
                  , (numSymbol "*", Times)
                  , (numSymbol "/", Div)
                  , (numSymbol "%", Mod)
                  ] 
  where
    numSymbol :: String -> Symbol
    numSymbol =  symbol . (++) "GHC.Num."

splitArgs e = (f, reverse es)
 where
    (f, es) = go e

    go (C.App (C.Var i) e) | ignoreVar i       = go e
    go (C.App f (C.Var v)) | isErasable v    = go f
    go (C.App f e) = (f', e:es) where (f', es) = go f
    go f           = (f, [])

tosymbol (C.Var x) = return $ dummyLoc $ simpleSymbolVar x
tosymbol  e        = throw ("Bad Measure Definition:\n" ++ showPpr e ++ "\t cannot be applied")

tosymbol' (C.Var x) = return $ dummyLoc $ simpleSymbolVar' x
tosymbol'  e        = throw ("Bad Measure Definition:\n" ++ showPpr e ++ "\t cannot be applied")

makesub (C.NonRec x e) =  (symbol x,) <$> coreToLogic e
makesub  _             = throw "Cannot make Logical Substitution of Recursive Definitions"

mkLit :: Literal -> Maybe Expr
mkLit (MachInt    n)   = mkI n
mkLit (MachInt64  n)   = mkI n
mkLit (MachWord   n)   = mkI n
mkLit (MachWord64 n)   = mkI n
mkLit (MachFloat  n)   = mkR n
mkLit (MachDouble n)   = mkR n
mkLit (LitInteger n _) = mkI n
mkLit _                = Nothing -- ELit sym sort
mkI                    = Just . ECon . I  
mkR                    = Just . ECon . F.R . fromRational

ignoreVar i = simpleSymbolVar i `elem` ["I#"]


simpleSymbolVar  = dropModuleNames . symbol . showPpr . getName
simpleSymbolVar' = symbol . showPpr . getName

isErasable v   = isPrefixOfSym (symbol ("$" :: String)) (simpleSymbolVar v)

isDead = isDeadOcc . occInfo . idInfo

class Simplify a where
  simplify :: a -> a 
  inline   :: (Id -> Bool) -> a -> a

instance Simplify C.CoreExpr where
  simplify e@(C.Var _) 
    = e
  simplify e@(C.Lit _) 
    = e
  simplify (C.App e (C.Type _))                        
    = simplify e
  simplify (C.App e (C.Var dict))  | isErasable dict 
    = simplify e
  simplify (C.App (C.Lam x e) _)   | isDead x          
    = simplify e
  simplify (C.App e1 e2) 
    = C.App (simplify e1) (simplify e2)
  simplify (C.Lam x e) | isTyVar x 
    = simplify e
  simplify (C.Lam x e) 
    = C.Lam x (simplify e)
  simplify (C.Let xes e) 
    = C.Let (simplify xes) (simplify e)
  simplify (C.Case e x t alts) 
    = C.Case (simplify e) x t (simplify <$> alts)
  simplify (C.Cast e _)    
    = simplify e
  simplify (C.Tick _ e) 
    = simplify e
  simplify (C.Coercion c)
    = C.Coercion c
  simplify (C.Type t)
    = C.Type t  

  inline p (C.Let (C.NonRec x ex) e) | p x
                               = sub (M.singleton x (inline p ex)) (inline p e)
  inline p (C.Let xes e)       = C.Let (inline p xes) (inline p e)  
  inline p (C.App e1 e2)       = C.App (inline p e1) (inline p e2)
  inline p (C.Lam x e)         = C.Lam x (inline p e)
  inline p (C.Case e x t alts) = C.Case (inline p e) x t (inline p <$> alts)
  inline p (C.Cast e c)        = C.Cast (inline p e) c
  inline p (C.Tick t e)        = C.Tick t (inline p e)
  inline _ (C.Var x)           = C.Var x
  inline _ (C.Lit l)           = C.Lit l
  inline _ (C.Coercion c)      = C.Coercion c
  inline _ (C.Type t)          = C.Type t


instance Simplify C.CoreBind where
  simplify (C.NonRec x e) = C.NonRec x (simplify e)
  simplify (C.Rec xes)    = C.Rec (mapSnd simplify <$> xes )

  inline p (C.NonRec x e) = C.NonRec x (inline p e)
  inline p (C.Rec xes)    = C.Rec (mapSnd (inline p) <$> xes)

instance Simplify C.CoreAlt where
  simplify (c, xs, e) = (c, xs, simplify e) 

  inline p (c, xs, e) = (c, xs, inline p e)

