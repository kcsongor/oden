{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Oden.Infer (
  Constraint,
  TypeError(..),
  Subst(..),
  TypeBinding(..),
  TypingEnvironment,
  inferExpr,
  inferDefinition,
  inferPackage,
  constraintsExpr
) where

import           Control.Monad.Except
import           Control.Monad.Identity
import           Control.Monad.RWS       hiding ((<>))

import qualified Data.Map                as Map
import qualified Data.Set                as Set

import qualified Oden.Core               as Core
import           Oden.Core.Operator
import qualified Oden.Core.Untyped       as Untyped
import           Oden.Environment        as Environment hiding (map)
import           Oden.Identifier
import           Oden.Infer.Environment
import           Oden.Infer.Substitution
import           Oden.Infer.Subsumption
import           Oden.Metadata
import           Oden.Predefined
import           Oden.QualifiedName      (QualifiedName(..))
import           Oden.SourceInfo
import           Oden.Type.Basic
import           Oden.Type.Polymorphic
import           Oden.Type.Signature

-------------------------------------------------------------------------------
-- Classes
-------------------------------------------------------------------------------

-- | Inference monad.
type Infer a = (RWST
                  TypingEnvironment -- Typing environment
                  [Constraint]              -- Generated constraints
                  InferState                -- Inference state
                  (Except                   -- Inference errors
                    TypeError)
                  a)                        -- Result

-- | Inference state.
data InferState = InferState { count :: Int }

-- | Initial inference state.
initInfer :: InferState
initInfer = InferState { count = 0 }

type Constraint = (SourceInfo, Type, Type)

type Unifier = (Subst, [Constraint])

-- | Constraint solver monad.
type Solve a = ExceptT TypeError Identity a


instance FTV Constraint where
  ftv (_, t1, t2) = ftv t1 `Set.union` ftv t2

instance Substitutable Constraint where
  apply s (si, t1, t2) = (si, apply s t1, apply s t2)

instance FTV TypeBinding where
  ftv (Package _ _ e)        = ftv e
  ftv (Local _ _ d)          = ftv d
  ftv (Type _ _ _ fs)        = ftv fs
  ftv (QuantifiedType _ _ t) = ftv t

instance Substitutable TypeBinding where
  apply _ (Package si n e)        = Package si n e
  apply s (Local si n d)          = Local si n (apply s d)
  apply s (Type si n bs t)        = Type si n bs (apply s t)
  apply s (QuantifiedType si n t) = QuantifiedType si n (apply s t)

instance FTV TypingEnvironment where
  ftv (Environment env) = ftv $ Map.elems env

instance Substitutable TypingEnvironment where
  apply s (Environment env) = Environment $ Map.map (apply s) env

data TypeError
  = UnificationFail SourceInfo Type Type
  | InfiniteType SourceInfo TVar Type
  | PackageNotInScope SourceInfo Identifier
  | NotInScope SourceInfo Identifier
  | MemberNotInPackage SourceInfo Identifier Identifier
  | UnificationMismatch SourceInfo [Type] [Type]
  | ArgumentCountMismatch (Core.Expr Type) [Type] [Type]
  | TypeSignatureSubsumptionError Identifier SubsumptionError
  | InvalidPackageReference SourceInfo Identifier
  | ValueUsedAsType SourceInfo Identifier
  | TypeIsNotAnExpression SourceInfo Identifier
  | InvalidTypeInStructInitializer SourceInfo Type
  | StructInitializerFieldCountMismatch SourceInfo Type [Type]
  deriving (Show, Eq)

-------------------------------------------------------------------------------
-- Inference
-------------------------------------------------------------------------------

-- | Run the inference monad.
runInfer :: TypingEnvironment -> Infer a -> Either TypeError (a, [Constraint])
runInfer env m = runExcept $ evalRWST m env initInfer

-- | Solve for the top-level type of an expression in a given typing
-- environment.
inferExpr :: TypingEnvironment
          -> Untyped.Expr
          -> Either TypeError Core.CanonicalExpr
inferExpr env ex = do
  (te, cs) <- runInfer env (infer ex)
  subst <- runSolve cs
  return $ closeOver (apply subst te)

-- | Return the internal constraints used in solving for the type of an
-- expression.
constraintsExpr :: TypingEnvironment
                -> Untyped.Expr
                -> Either TypeError ([Constraint], Subst, Core.Expr Type, Scheme)
constraintsExpr env ex = do
  (te, cs) <- runInfer env (infer ex)
  subst <- runSolve cs
  let (sc, te') = closeOver $ apply subst te
  return (cs, subst, te', sc)

-- | Canonicalize and return the polymorphic top-level type.
closeOver :: Core.Expr Type -> Core.CanonicalExpr
closeOver = normalize . generalize empty

-- | Unify two types. Order matters in some cases as the first type is the one
-- being subsumed by the second, e.g. when unifying with TAny.
uni :: SourceInfo -> Type -> Type -> Infer ()
uni si t1 t2 = tell [(si, t1, t2)]

-- | Extend the typing environment.
inEnv :: (Identifier, TypeBinding) -> Infer a -> Infer a
inEnv (x, sc) = local (`extend` (x, sc))

lookupTypeIn :: TypingEnvironment -> Metadata SourceInfo -> Identifier -> Infer Type
lookupTypeIn _ si (Identifier "any") = return (TAny si)
lookupTypeIn _ si (Identifier "int") = return (TBasic si TInt)
lookupTypeIn _ si (Identifier "bool") = return (TBasic si TBool)
lookupTypeIn _ si (Identifier "string") = return (TBasic si TString)
lookupTypeIn env (Metadata si) identifier =
  case Environment.lookup identifier env of
    Nothing                          -> throwError $ NotInScope si identifier
    Just Package{}                   -> throwError $ InvalidPackageReference si identifier
    Just (Local _ _ _)               -> throwError $ ValueUsedAsType si identifier
    Just (Type _ typeIdentifier _ t) -> return $ TNamed (Metadata si) typeIdentifier t
    Just (QuantifiedType _ _ t)      -> return t

-- | Lookup a type in the environment.
lookupType :: Metadata SourceInfo -> Identifier -> Infer Type
lookupType si identifier = do
  env <- ask
  lookupTypeIn env si identifier

lookupValueIn :: TypingEnvironment -> Metadata SourceInfo -> Identifier -> Infer Type
lookupValueIn env (Metadata si) identifier = do
  type' <- case Environment.lookup identifier env of
            Nothing               -> throwError $ NotInScope si identifier
            Just Package{}        -> throwError $ InvalidPackageReference si identifier
            Just (Local _ _ sc)   -> instantiate sc
            Just Type{}           -> throwError (TypeIsNotAnExpression si identifier)
            Just QuantifiedType{} -> throwError (TypeIsNotAnExpression si identifier)
  return $ setSourceInfo si type'

-- | Lookup type of a value in the environment.
lookupValue :: Metadata SourceInfo -> Identifier -> Infer Type
lookupValue si identifier = do
  env <- ask
  lookupValueIn env si identifier
letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

-- | Create a new type variable with a unique name.
fresh :: Metadata SourceInfo -> Infer Type
fresh si = do
    s <- get
    put s{count = count s + 1}
    return $ TVar si (TV ("_t" ++ (show $ count s)))

-- | Create a type based on scheme but with all fresh type variables.
instantiate :: Scheme -> Infer Type
instantiate (Forall _ as t) = do
    as' <- mapM (fresh . Metadata . getSourceInfo) as
    let s = Subst $ Map.fromList $ zip (map getBindingVar as) as'
    return $ apply s t

-- | Given a typed expression, return a canonical expression with the free
-- type variables (not present in the environment) declared as type variable
-- bindings for the expression.
generalize :: TypingEnvironment -> Core.Expr Type -> Core.CanonicalExpr
generalize env expr  = (Forall (Metadata $ getSourceInfo expr) bindings (Core.typeOf expr), expr)
    where bindings = map (TVarBinding $ Metadata Missing) (Set.toList $ ftv expr `Set.difference` ftv env)

-- | The heart of the inferencer. Takes an untyped expression and returns the
-- inferred typed expression. Constraints are collected in the 'Infer' monad
-- and substitutions are made before the inference is complete, so the
-- expressions returned from 'infer' are not the final results.
infer :: Untyped.Expr -> Infer (Core.Expr Type)
infer expr = case expr of
  Untyped.Literal si Untyped.Unit ->
    return (Core.Literal si Core.Unit (TUnit si))
  Untyped.Literal si (Untyped.Int n) ->
    return (Core.Literal si (Core.Int n) (TBasic si TInt))
  Untyped.Literal si (Untyped.Bool b) ->
    return (Core.Literal si (Core.Bool b) (TBasic si TBool))
  Untyped.Literal si (Untyped.String s) ->
    return (Core.Literal si (Core.String s) (TBasic si TString))

  Untyped.Subscript si s i -> do
    st <- infer s
    it <- infer i
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (Metadata $ getSourceInfo s) tv)
    uni (getSourceInfo it) (Core.typeOf it) (TBasic si TInt)
    return (Core.Subscript si st it tv)

  Untyped.Subslice si s (Untyped.Range e1 e2) -> do
    st <- infer s
    e1t <- infer e1
    e2t <- infer e2
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (Metadata $ getSourceInfo s) tv)
    uni (getSourceInfo e1t) (Core.typeOf e1t) (TBasic si TInt)
    uni (getSourceInfo e2t) (Core.typeOf e2t) (TBasic si TInt)
    return (Core.Subslice si st (Core.Range e1t e2t) (TSlice si tv))

  Untyped.Subslice si s (Untyped.RangeTo e) -> do
    st <- infer s
    et <- infer e
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (Metadata $ getSourceInfo s) tv)
    uni (getSourceInfo et) (Core.typeOf et) (TBasic si TInt)
    return (Core.Subslice si st (Core.RangeTo et) (TSlice si tv))

  Untyped.Subslice si s (Untyped.RangeFrom e) -> do
    st <- infer s
    et <- infer e
    tv <- fresh si
    uni (getSourceInfo st) (Core.typeOf st) (TSlice (Metadata $ getSourceInfo s) tv)
    uni (getSourceInfo et) (Core.typeOf et) (TBasic si TInt)
    return (Core.Subslice si st (Core.RangeFrom et) (TSlice si tv))

  Untyped.UnaryOp si o e -> do
    rt <- case o of
              Positive   -> return (TBasic si TInt)
              Negative -> return (TBasic si TInt)
              Not    -> return (TBasic si TBool)
    te <- infer e
    uni (getSourceInfo te) (Core.typeOf te) rt
    return (Core.UnaryOp si o te rt)

  Untyped.BinaryOp si o e1 e2 -> do
    (ot, rt) <- case o of
                    Add               -> return (TBasic si TInt, TBasic si TInt)
                    Subtract          -> return (TBasic si TInt, TBasic si TInt)
                    Multiply          -> return (TBasic si TInt, TBasic si TInt)
                    Divide            -> return (TBasic si TInt, TBasic si TInt)
                    Equals            -> do tv <- fresh si
                                            return (tv, TBasic si TBool)
                    Concat            -> return (TBasic si TString, TBasic si TString)
                    LessThan          -> return (TBasic si TInt, TBasic si TBool)
                    GreaterThan       -> return (TBasic si TInt, TBasic si TBool)
                    LessThanEqual     -> return (TBasic si TInt, TBasic si TBool)
                    GreaterThanEqual  -> return (TBasic si TInt, TBasic si TBool)
                    And               -> return (TBasic si TBool, TBasic si TBool)
                    Or                -> return (TBasic si TBool, TBasic si TBool)
    te1 <- infer e1
    te2 <- infer e2
    uni (getSourceInfo te1) (Core.typeOf te1) ot
    uni (getSourceInfo te2) (Core.typeOf te2) ot
    return (Core.BinaryOp si o te1 te2 rt)

  Untyped.Symbol si x -> do
    t <- lookupValue si x
    return $ Core.Symbol si x t

  Untyped.MemberAccess si expr'@(Untyped.Symbol symbolSourceInfo name) memberName -> do
    env <- ask
    case Environment.lookup name env of
      Just (Package _ _ pkgEnv) -> do
        valueType <- lookupValueIn pkgEnv si memberName
        return (Core.PackageMemberAccess si name memberName valueType)
      Just _ -> inferStructFieldAccess si expr' memberName
      Nothing -> throwError $ NotInScope (unwrap symbolSourceInfo) name

  Untyped.MemberAccess si expr' fieldName ->
    inferStructFieldAccess si expr' fieldName

  Untyped.Fn si (Untyped.NameBinding bsi a) b -> do
    tv <- fresh bsi
    tb <- inEnv (a, Local bsi a (Forall bsi [] tv)) (infer b)
    return (Core.Fn si (Core.NameBinding bsi a) tb (TFn si tv (Core.typeOf tb)))

  Untyped.NoArgFn si f -> do
    tf <- infer f
    return (Core.NoArgFn si tf (TNoArgFn si (Core.typeOf tf)))

  Untyped.Application si f [] -> do
    tv <- fresh si
    tf <- infer f
    case Core.typeOf tf of
      t@TUncurriedFn{} -> do
        uni (getSourceInfo tf) t (TUncurriedFn (Metadata $ getSourceInfo tf) [] tv)
        return (Core.UncurriedFnApplication si tf [] tv)
      -- No-param application of variadic function is automatically transformed
      -- to application of empty slice.
      t@(TVariadicFn _ [] variadicArg _) -> do
        uni (getSourceInfo tf) t (TVariadicFn (Metadata $ getSourceInfo tf) [] variadicArg tv)
        return (Core.UncurriedFnApplication si tf [Core.Slice (Metadata $ getSourceInfo variadicArg) [] variadicArg] tv)
      TVariadicFn _ nonVariadicArgs _ _ ->
        throwError (ArgumentCountMismatch tf nonVariadicArgs [])
      t -> do
        uni (getSourceInfo tf) t (TNoArgFn (Metadata $ getSourceInfo tf) tv)
        return (Core.NoArgApplication si tf tv)

  Untyped.Application si f ps -> do
    tf <- infer f
    case Core.typeOf tf of
      t@TUncurriedFn{} -> do
        tv <- fresh (Metadata $ getSourceInfo t)
        tps <- mapM infer ps
        uni (getSourceInfo tf) t (TUncurriedFn si (map Core.typeOf tps) tv)
        return (Core.UncurriedFnApplication si tf tps tv)
      t@(TVariadicFn _ nonVariadicTypes variadicType _) -> do
        tv <- fresh (Metadata $ getSourceInfo t)
        nonVariadicParams <- mapM infer (take (length nonVariadicTypes) ps)
        variadicParams <- mapM infer (drop (length nonVariadicTypes) ps)
        let sliceSi = if null variadicParams then Missing else getSourceInfo (head variadicParams)
        let allParams = nonVariadicParams ++ [Core.Slice (Metadata sliceSi) variadicParams variadicType]
        uni (getSourceInfo tf) t (TVariadicFn (Metadata $ getSourceInfo tf) (map Core.typeOf nonVariadicParams) variadicType tv)
        return (Core.UncurriedFnApplication si tf allParams tv)
      t ->
        foldM app tf ps
        where
        app :: Core.Expr Type -> Untyped.Expr -> Infer (Core.Expr Type)
        app tf' p = do
          tv <- fresh (Metadata $ getSourceInfo t)
          tp <- infer p
          uni (getSourceInfo tf) (Core.typeOf tf') (TFn (Metadata $ getSourceInfo tf) (Core.typeOf tp) tv)
          return (Core.Application si tf' tp tv)

  Untyped.Let si (Untyped.NameBinding bsi n) e b -> do
    te <- infer e
    tb <- inEnv (n, Local bsi n (Forall si [] (Core.typeOf te))) (infer b)
    return (Core.Let si (Core.NameBinding bsi n) te tb (Core.typeOf tb))

  Untyped.If si cond tr fl -> do
    tcond <- infer cond
    ttr <- infer tr
    tfl <- infer fl
    uni (getSourceInfo tcond) (Core.typeOf tcond) (TBasic si TBool)
    uni (getSourceInfo ttr) (Core.typeOf ttr) (Core.typeOf tfl)
    return (Core.If si tcond ttr tfl (Core.typeOf ttr))

  Untyped.Tuple si f s r -> do
    tf <- infer f
    ts <- infer s
    tr <- mapM infer r
    let t = TTuple si (Core.typeOf tf) (Core.typeOf ts) (map Core.typeOf tr)
    return (Core.Tuple si tf ts tr t)

  Untyped.Slice si es -> do
    tv <- fresh si
    tes <- mapM infer es
    mapM_ (uni (unwrap si) tv . Core.typeOf) tes
    return (Core.Slice si tes (TSlice si tv))

  Untyped.Block si es -> do
    tv <- fresh si
    tes <- mapM infer es
    case tes of
      [] -> uni (unwrap si) tv (TUnit si)
      _ -> uni (unwrap si) tv (Core.typeOf (last tes))
    return (Core.Block si tes tv)

  Untyped.StructInitializer si ts values -> do
    t <- resolveType ts
    typedValues <- mapM infer values
    case underlying t of
      TStruct _ fields -> do
        let typedExpr = Core.StructInitializer si t typedValues

        -- Make sure the struct has at least as many values as being used in
        -- the initialization.
        when (length values > length fields) $
          throwError $
            StructInitializerFieldCountMismatch (unwrap si) t (map Core.typeOf typedValues)

        zipWithM_ unifyField fields typedValues
        return typedExpr
        where
        unifyField (TStructField fsi _ ft) te = uni (unwrap fsi) ft (Core.typeOf te)
      _ -> throwError $ InvalidTypeInStructInitializer (unwrap si) t

  where
  inferStructFieldAccess si expr' fieldName = do
    tv <- fresh si
    typedExpr <- infer expr'
    uni (getSourceInfo typedExpr)
        (Core.typeOf typedExpr)
        (TStruct (Metadata $ getSourceInfo typedExpr) [TStructField si fieldName tv])
    return (Core.StructFieldAccess si typedExpr fieldName tv)

-- | Tries to resolve a user-supplied type expression to an actual type.
resolveType :: SignatureExpr SourceInfo -> Infer Type
resolveType (TSUnit si) = return (TUnit (Metadata si))
resolveType (TSSymbol si i) = lookupType (Metadata si) i
resolveType (TSApp _si _e1 _e2) = error "Type constructor application not implemented yet."
resolveType (TSFn si de re) = TFn (Metadata si) <$> resolveType de <*> resolveType re
resolveType (TSNoArgFn si e) = TNoArgFn (Metadata si) <$> resolveType e
resolveType (TSTuple si fe se re) = TTuple (Metadata si) <$> resolveType fe
                                                         <*> resolveType se
                                                         <*> mapM resolveType re
resolveType (TSSlice si e) = TSlice (Metadata si) <$> resolveType e
resolveType (TSStruct si fields) = TStruct (Metadata si) <$> mapM resolveStructFieldType fields
  where
  resolveStructFieldType (TSStructField fsi name expr) =
    TStructField (Metadata fsi) name <$> resolveType expr

-- | Tries to resolve a user-supplied type signature to an actual type scheme.
resolveTypeSignature :: TypeSignature SourceInfo -> Infer (Scheme, TypingEnvironment)
resolveTypeSignature (TypeSignature si bindings expr) = do
  env <- ask
  envWithBindings <- foldM extendWithBinding env bindings
  t <- local (const envWithBindings) (resolveType expr)
  return (Forall (Metadata si) (map toVarBinding bindings) t, envWithBindings)
  where
  extendWithBinding env' (SignatureVarBinding si' v) = do
    tv <- fresh (Metadata si')
    return $ env' `extend` (v, QuantifiedType (Metadata si') v tv)
  toVarBinding (SignatureVarBinding si' (Identifier v)) = TVarBinding (Metadata si') (TV v)

-- | Indicates if the canonical expression should be generated by closing over
-- the the free type variables in the inferred expression. This is done when
-- top type signatures are missing.
type ShouldCloseOver = Bool

-- | Infer the untyped definition in the Infer monad, returning a typed
-- version. Resolves type signatures of optionally type-annotated definitions.
inferDef :: Untyped.Definition -> Infer (Core.Definition, ShouldCloseOver)
inferDef (Untyped.Definition si name s expr) = do
  env <- ask
  case s of
    Nothing -> do
      tv <- fresh si
      let recScheme = Forall si [] tv
      let recursiveEnv = env `extend` (name, Local si name recScheme)
      te <- local (const recursiveEnv) (infer expr)
      return (Core.Definition si name (recScheme, te), True)
    Just ts -> do
      (recScheme@(Forall _ _ recType), envWithBindings) <- resolveTypeSignature ts
      let recursiveEnv = envWithBindings  `extend` (name, Local si name recScheme)
      te <- local (const recursiveEnv) (infer expr)
      uni (getSourceInfo te) recType (Core.typeOf te)
      case recScheme `subsumedBy` te of
        Left e -> throwError $ TypeSignatureSubsumptionError name e
        Right canonical -> return (Core.Definition si name canonical, False)

inferDef (Untyped.TypeDefinition si name params typeExpr) = do
  type' <- resolveType typeExpr
  return (Core.TypeDefinition si name (map convertParams params) type', False)
  where
  convertParams (Untyped.NameBinding bsi bn) = Core.NameBinding bsi bn

-- | Infer a top-level definitition, returning a typed version and the typing
-- environment extended with the definitions name and type.
inferDefinition :: TypingEnvironment -> Untyped.Definition -> Either TypeError (TypingEnvironment, Core.Definition)
inferDefinition env def = do
  -- Infer the definition.
  ((def', shouldCloseOver), cs) <- runInfer env (inferDef def)

  case def' of
    Core.Definition si name (_, te) | shouldCloseOver -> do
      subst <- runSolve cs
      let canonical'@(sc, _) = closeOver (apply subst te)
          env' = env `extend` (name, Local si name sc)
      return (env', Core.Definition si name canonical')
    Core.Definition si name canonical -> do
      subst <- runSolve cs
      let canonical'@(sc, _) = normalize (apply subst canonical)
          env' = env `extend` (name, Local si name sc)
      return (env', Core.Definition si name canonical')

    Core.TypeDefinition si name@(FQN _ localName) params type' ->
      return (env `extend` (localName, Type si name params type'), def')

    Core.ForeignDefinition _ name _ ->
      error ("unexpected foreign definition: " ++ asString name)

-- | Infer the package, returning a package with typed definitions along with
-- the extended typing environment.
inferPackage :: Untyped.Package [Core.ImportedPackage]
             -> Either TypeError Core.Package
inferPackage (Untyped.Package (Untyped.PackageDeclaration psi name) imports defs) = do
  let env = fromPackage universe `merge` fromPackages imports
  inferred <- snd <$> foldM iter (env, []) defs
  return (Core.Package (Core.PackageDeclaration psi name) imports inferred)
  where
  iter (e, inferred) def = do
      (e', def') <- inferDefinition e def
      return (e', inferred ++ [def'])

-- | Swaps all type variables names for generated ones based on 'letters' to
-- get a nice sequence.
normalize :: (Scheme, Core.Expr Type) -> (Scheme, Core.Expr Type)
normalize (Forall si _ exprType, te) =
  (Forall si newBindings (apply subst exprType), apply subst te)
  where
    -- Pairs of existing type variables in the type and new type variables
    -- values to substitute with, a sequence based on 'letters'.
    substPairs = zip (Set.toList $ ftv exprType) (map TV letters)
    -- The substitution based on the pairs.
    subst = Subst (Map.fromList (map wrapTvar substPairs))
    wrapTvar (tv1, tv2) = (tv1, TVar (Metadata Missing) tv2)
    -- The new set of type variables bindings for the canonical expression.
    newBindings = map (TVarBinding (Metadata Missing) . snd) substPairs

-------------------------------------------------------------------------------
-- Constraint Solver
-------------------------------------------------------------------------------

-- | Run the constraint solver
runSolve :: [Constraint] -> Either TypeError Subst
runSolve cs = runIdentity $ runExceptT $ solver st
  where st = (emptySubst, cs)

-- | Unifies the corresponding types in the lists (like a zip).
unifyMany :: SourceInfo -> [Type] -> [Type] -> Solve Subst
unifyMany _ [] [] = return emptySubst
unifyMany si (t1 : ts1) (t2 : ts2) =
  do su1 <- unifies si t1 t2
     su2 <- unifyMany si (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyMany si t1 t2 = throwError $ UnificationMismatch si t1 t2

-- | Unify two types, returning the resulting substitution. Order matters in
-- some cases as the first type is the one being subsumed by the second, e.g.
-- when unifying with TAny.
unifies :: SourceInfo -> Type -> Type -> Solve Subst
unifies _ (TVar _ v) t = v `bind` t
unifies _ t (TVar _ v) = v `bind` t
unifies _ TAny{} _ = return emptySubst
unifies si t1@(TBasic _ b1) t2@(TBasic _ b2)
  | b1 == b2 = return emptySubst
  | otherwise = throwError $ UnificationFail si t1 t2
unifies _ TUnit{} TUnit{} = return emptySubst
unifies _ t1@TCon{} t2@TCon{}
  | t1 == t2  = return emptySubst
  | otherwise = throwError $ UnificationFail (getSourceInfo t1) t1 t2
unifies si (TFn _ t1 t2) (TFn _ t3 t4) = unifyMany si [t1, t2] [t3, t4]
unifies si (TNoArgFn _ t1) (TNoArgFn _ t2) = unifies si t1 t2
unifies si (TUncurriedFn _ as1 r1) (TUncurriedFn _ as2 r2) = do
  a <- unifyMany si as1 as2
  r <- unifies si r1 r2
  return (a `compose` r)
unifies si (TVariadicFn _ as1 v1 r1) (TVariadicFn _ as2 v2 r2) = do
  a <- unifyMany si as1 as2
  v <- unifies si v1 v2
  r <- unifies si r1 r2
  return (a `compose` v `compose` r)
unifies si (TTuple _ f1 s1 r1) (TTuple _ f2 s2 r2) = do
  f <- unifies si f1 f2
  s <- unifies si s1 s2
  r <- unifyMany si r1 r2
  return (f `compose` s `compose` r)
unifies si (TSlice _ t1) (TSlice _ t2) = unifies si t1 t2
unifies si (TNamed _ n1 t1) (TNamed _ n2 t2)
  | n1 == n2 = unifies si t1 t2
unifies si t1 (TNamed _ _ t2) = unifies si t1 t2
unifies si (TNamed _ _ t1) t2 = unifies si t1 t2
unifies si (TStruct _ fs1) (TStruct _ fs2) =
  unifyMany si (map getStructFieldType fs1) (map getStructFieldType fs2)
unifies si t1 t2 = throwError $ UnificationFail si t1 t2

-- Unification solver
solver :: Unifier -> Solve Subst
solver (su, cs) =
  case cs of
    [] -> return su
    ((si, t1, t2): cs0) -> do
      su1  <- unifies si t1 t2
      solver (su1 `compose` su, apply su1 cs0)

-- | Create a substitution from the 'TVar' to the 'Type', as long as the 'TVar'
-- does not occur in the 'Type'. In that case we have an infinite type, which
-- is an error.
bind ::  TVar -> Type -> Solve Subst
bind a (TVar _ v) | v == a = return emptySubst
bind a t
  | occursCheck a t = throwError $ InfiniteType (getSourceInfo t) a t
  | otherwise       = return (Subst $ Map.singleton a t)

-- | Check if the 'TVar' occurs in the 'Type'.
occursCheck ::  Substitutable a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t
