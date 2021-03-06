{-# LANGUAGE NoImplicitPrelude, DeriveDataTypeable, DeriveGeneric, OverloadedStrings, TemplateHaskell #-}
module Lamdu.Infer
    ( makeScheme
    , TypeVars(..)
    , Dependencies(..), depsGlobalTypes, depsNominals, depSchemes
    , infer, inferFromNom, inferApply
    , Scope, emptyScope, Scope.scopeToTypeMap, Scope.insertTypeOf, Scope.skolems, Scope.skolemScopeVars
    , Payload(..), plScope, plType
    , M.Context, M.initialContext
    , M.InferCtx(..), M.inferCtx, Infer
    , freshInferredVarName
    , freshInferredVar
    , applyNominal
    ) where

import           AST (Tree, Ann(..), annotations)
import           AST.Term.Nominal (ToNom(..))
import           AST.Term.Row (RowExtend(..))
import           Control.DeepSeq (NFData(..))
import qualified Control.Lens as Lens
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Data.Binary (Binary)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (fromMaybe)
import           Data.Semigroup (Semigroup(..))
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           Lamdu.Calc.Term (Val)
import qualified Lamdu.Calc.Term as V
import           Lamdu.Calc.Type (Type)
import qualified Lamdu.Calc.Type as T
import           Lamdu.Calc.Type.Nominal (Nominal(..), nomParams, nomType)
import           Lamdu.Calc.Type.Scheme (Scheme)
import           Lamdu.Calc.Type.Vars (TypeVars(..))
import qualified Lamdu.Calc.Type.Vars as TV
import qualified Lamdu.Infer.Error as Err
import           Lamdu.Infer.Internal.Monad (Infer)
import qualified Lamdu.Infer.Internal.Monad as M
import           Lamdu.Infer.Internal.Scheme (makeScheme)
import qualified Lamdu.Infer.Internal.Scheme as Scheme
import           Lamdu.Infer.Internal.Scope (Scope, emptyScope, SkolemScope)
import qualified Lamdu.Infer.Internal.Scope as Scope
import           Lamdu.Infer.Internal.Subst (CanSubst(..))
import qualified Lamdu.Infer.Internal.Subst as Subst
import           Lamdu.Infer.Internal.Unify (unifyUnsafe)

import           Prelude.Compat

data Payload = Payload
    { _plType :: Type
    , _plScope :: Scope
    } deriving (Generic, Typeable, Show)
instance NFData Payload
instance Binary Payload

Lens.makeLenses ''Payload

instance TV.Free Payload where
    free (Payload typ scope) =
        TV.free typ <> TV.free scope

instance CanSubst Payload where
    apply s (Payload typ scope) =
        Payload (Subst.apply s typ) (Subst.apply s scope)

data Dependencies = Deps
    { _depsGlobalTypes :: Map V.Var Scheme
    , _depsNominals :: Map T.NominalId Nominal
    } deriving (Generic, Show, Eq, Ord)
instance NFData Dependencies
instance Binary Dependencies

Lens.makeLenses ''Dependencies

instance Semigroup Dependencies where
    Deps t0 n0 <> Deps t1 n1 = Deps (t0 <> t1) (n0 <> n1)
instance Monoid Dependencies where
    mempty = Deps Map.empty Map.empty
    mappend = (<>)

depSchemes :: Lens.Traversal' Dependencies Scheme
depSchemes f (Deps globals nominals) =
    Deps
    <$> traverse f globals
    <*> (traverse . nomType) f nominals

inferSubst :: Dependencies -> Scope -> Val a -> Infer (Scope, Val (Payload, a))
inferSubst deps rootScope val =
    do
        prevSubst <- M.getSubst
        let rootScope' = Subst.apply prevSubst rootScope
        (inferredVal, s) <- M.listenSubst $ inferInternal mkPayload deps rootScope' val
        pure (rootScope', inferredVal & annotations . _1 %~ Subst.apply s)
    where
        mkPayload typ scope dat = (Payload typ scope, dat)

-- All accessed global IDs are supposed to be extracted from the
-- expression to build this global scope. This is slightly hacky but
-- much faster than a polymorphic monad underlying the InferCtx monad
-- allowing global access.
-- Use loadInfer for a safer interface
infer :: Dependencies -> Scope -> Val a -> Infer (Val (Payload, a))
infer deps scope val =
    do
        ((scope', val'), results) <- M.listenNoTell $ inferSubst deps scope val
        M.tell $ results & M.subst %~ Subst.intersect (TV.free scope')
        pure val'

data CompositeHasTag = HasTag | DoesNotHaveTag | MayHaveTag T.RowVar

hasTag :: T.Tag -> T.Row -> CompositeHasTag
hasTag _ T.REmpty   = DoesNotHaveTag
hasTag _ (T.RVar v) = MayHaveTag v
hasTag tag (T.RExtend t _ r)
    | tag == t  = HasTag
    | otherwise = hasTag tag r

type InferHandler a b =
    (Scope -> a -> Infer (Type, Tree (Ann b) V.Term)) -> Scope ->
    M.Infer (Tree V.Term (Ann b), Type)

{-# INLINE freshInferredVar #-}
freshInferredVar :: (M.VarKind t, Monad m) => Scope -> String -> M.InferCtx m t
freshInferredVar = M.freshInferredVar . Scope.skolems

{-# INLINE freshInferredVarName #-}
freshInferredVarName :: (M.VarKind t, Monad m) => Scope -> String -> M.InferCtx m (T.Var t)
freshInferredVarName = M.freshInferredVarName . Scope.skolems

-- The "redundant" lambda tells GHC the argument saturation needed for
-- inlining
{-# ANN module ("HLint: ignore Redundant lambda" :: String) #-}

{-# INLINE inferLeaf #-}
inferLeaf :: Dependencies -> V.Leaf -> InferHandler a b
inferLeaf deps leaf = \_go locals ->
    case leaf of
    V.LHole -> freshInferredVar locals "h"
    V.LVar n ->
        case Scope.lookupTypeOf n locals of
        Just t -> pure t
        Nothing ->
            case Map.lookup n (deps ^. depsGlobalTypes) of
            Just s -> Scheme.instantiate (Scope.skolems locals) s
            Nothing -> M.throwError $ Err.UnboundVariable n
    V.LLiteral (V.PrimVal p _) -> pure $ T.TInst p Map.empty
    V.LRecEmpty -> pure $ T.TRecord T.REmpty
    V.LAbsurd -> freshInferredVar locals "a" <&> T.TFun (T.TVariant T.REmpty)
    V.LFromNom n -> inferFromNom (deps ^. depsNominals) n locals
    <&> (,) (V.BLeaf leaf)

{-# INLINE inferAbs #-}
inferAbs :: Tree (V.Lam V.Var V.Term) (Ann a) -> InferHandler (Val a) b
inferAbs (V.Lam n e) =
    \go locals ->
    do
        tv <- freshInferredVar locals "a"
        let locals' = Scope.insertTypeOf n tv locals
        ((t1, e'), s1) <- M.listenSubst $ go locals' e
        pure (V.BLam (V.Lam n e'), T.TFun (Subst.apply s1 tv) t1)

{-# INLINE inferApply #-}
inferApply :: Tree (V.Apply V.Term) (Ann a) -> InferHandler (Val a) b
inferApply (V.Apply e1 e2) =
    \go locals ->
    do
        ((p1_t1, e1'), p1_s) <- M.listenSubst $ go locals e1
        let p1 = Subst.apply p1_s

        ((p2_t2, e2'), p2_s) <- M.listenSubst $ go (p1 locals) e2
        let p2_t1 = Subst.apply p2_s p1_t1
        p2_tv <- freshInferredVar locals "a"

        ((), p3_s) <- M.listenSubst $ unifyUnsafe p2_t1 (T.TFun p2_t2 p2_tv)
        let p3_tv = Subst.apply p3_s p2_tv
        pure (V.BApp (V.Apply e1' e2'), p3_tv)

{-# INLINE inferGetField #-}
inferGetField :: V.GetField a -> InferHandler a b
inferGetField (V.GetField e name) = \go locals ->
    do
        (p1_t, e') <- go locals e
        p1_tv <- freshInferredVar locals "a"
        p1_tvRecName <- freshInferredVarName locals "r"
        M.tellRowConstraint p1_tvRecName name

        ((), p2_s) <-
            M.listenSubst $ unifyUnsafe p1_t $
            T.TRecord $ T.RExtend name p1_tv $ TV.lift p1_tvRecName
        let p2_tv = Subst.apply p2_s p1_tv
        pure (V.BGetField (V.GetField e' name), p2_tv)

{-# INLINE inferInject #-}
inferInject :: V.Inject a -> InferHandler a b
inferInject (V.Inject name e) = \go locals ->
    do
        (t, e') <- go locals e
        tvVariantName <- freshInferredVarName locals "s"
        M.tellRowConstraint tvVariantName name
        pure
            ( V.BInject (V.Inject name e')
            , T.TVariant $ T.RExtend name t $ TV.lift tvVariantName
            )

{-# INLINE inferCase #-}
inferCase :: Tree (RowExtend T.Tag V.Term V.Term) (Ann a) -> InferHandler (Val a) b
inferCase (RowExtend name m mm) = \go locals ->
    do
        ((p1_tm, m'), p1_s) <- M.listenSubst $ go locals m
        let p1 = Subst.apply p1_s
        -- p1
        ((p2_tmm, mm'), p2_s) <- M.listenSubst $ go (p1 locals) mm
        let p2 = Subst.apply p2_s
            p2_tm = p2 p1_tm
        -- p2
        p2_tv <- freshInferredVar locals "a"
        p2_tvRes <- freshInferredVar locals "res"
        -- type(match) `unify` a->res
        ((), p3_s) <-
            M.listenSubst $ unifyUnsafe p2_tm $ T.TFun p2_tv p2_tvRes
        let p3 = Subst.apply p3_s
            p3_tv    = p3 p2_tv
            p3_tvRes = p3 p2_tvRes
            p3_tmm   = p3 p2_tmm
        -- p3
        -- new variant type var "s":
        tvVariantName <- freshInferredVarName locals "s"
        M.tellRowConstraint tvVariantName name
        let p3_tvVariant = TV.lift tvVariantName
        -- type(mismatch) `unify` [ s ]->res
        ((), p4_s) <-
            M.listenSubst $ unifyUnsafe p3_tmm $
            T.TFun (T.TVariant p3_tvVariant) p3_tvRes
        let p4 :: CanSubst a => a -> a
            p4 = Subst.apply p4_s
            p4_tvVariant = p4 p3_tvVariant
            p4_tvRes     = p4 p3_tvRes
            p4_tv        = p4 p3_tv
        -- p4
        pure
            ( V.BCase (RowExtend name m' mm')
            , T.TFun (T.TVariant (T.RExtend name p4_tv p4_tvVariant)) p4_tvRes
            )

{-# INLINE inferRecExtend #-}
inferRecExtend :: Tree (RowExtend T.Tag V.Term V.Term) (Ann a) -> InferHandler (Val a) b
inferRecExtend (RowExtend name e1 e2) = \go locals ->
    do
        ((t1, e1'), s1) <- M.listenSubst $ go locals e1
        ((t2, e2'), s2) <- M.listenSubst $ go (Subst.apply s1 locals) e2
        (rest, s3) <-
            M.listenSubst $
            case t2 of
            T.TRecord x ->
                -- In case t2 is already inferred as a TRecord,
                -- verify it doesn't already have this field,
                -- and avoid unnecessary unify from other case
                case hasTag name x of
                HasTag -> M.throwError $ Err.DuplicateField name x
                DoesNotHaveTag -> pure x
                MayHaveTag var -> x <$ M.tellRowConstraint var name
            _ -> do
                tv <- freshInferredVarName locals "r"
                M.tellRowConstraint tv name
                let tve = TV.lift tv
                ((), s) <- M.listenSubst $ unifyUnsafe t2 $ T.TRecord tve
                pure $ Subst.apply s tve
        let t1' = Subst.apply s3 $ Subst.apply s2 t1
        pure
            ( V.BRecExtend (RowExtend name e1' e2')
            , T.TRecord $ T.RExtend name t1' rest
            )

getNominal :: Map T.NominalId Nominal -> T.NominalId -> M.Infer Nominal
getNominal nominals name =
    case Map.lookup name nominals of
    Nothing -> M.throwError $ Err.MissingNominal name
    Just nominal -> pure nominal

-- errorizes if the map mismatches the map in the Nominal
applyNominal :: Map T.ParamId Type -> Nominal -> Scheme
applyNominal m (Nominal params scheme) =
    Subst.apply subst scheme
    where
        subst = mempty { Subst.substTypes = Map.mapKeys (`find` params) m }
        find k =
            fromMaybe (error "Nominal.instantiate with wrong param map") .
            Map.lookup k

nomTypes :: SkolemScope -> Map T.NominalId Nominal -> T.NominalId -> M.Infer (Type, Scheme)
nomTypes outerSkolemsScope nominals name =
    do
        nominal <- getNominal nominals name
        p1_paramVals <-
            nominal ^. nomParams
            & Map.keysSet & Map.fromSet (const (M.freshInferredVar outerSkolemsScope "n"))
            & sequenceA
        pure (T.TInst name p1_paramVals, applyNominal p1_paramVals nominal)

{-# INLINE inferFromNom #-}
inferFromNom ::
    Map T.NominalId Nominal -> T.NominalId -> Scope ->
    M.InferCtx (Either Err.Error) Type
inferFromNom nominals n locals =
    do
        (outerType, innerScheme) <-
            nomTypes (Scope.skolems locals) nominals n
        innerType <- Scheme.instantiate (Scope.skolems locals) innerScheme
        T.TFun outerType innerType & pure

{-# INLINE inferToNom #-}
inferToNom :: Map T.NominalId Nominal -> Tree (ToNom T.NominalId V.Term) k -> InferHandler (Tree k V.Term) a
inferToNom nominals (ToNom name val) = \go locals ->
    do
        (p1_outerType, p1_innerScheme) <- nomTypes (Scope.skolems locals) nominals name
        ((skolemRenames, p1_innerType), instantiateResults) <-
            M.listen $ Scheme.instantiateWithRenames (Scope.skolems locals) p1_innerScheme
        let skolems = TV.renameDest skolemRenames
        M.addSkolems skolems $ M._constraints instantiateResults
        (p1_t, val') <- go (Scope.insertSkolems skolems locals) val
        ((), p2_s) <- M.listenSubst $ unifyUnsafe p1_t p1_innerType
        let p2_outerType = Subst.apply p2_s p1_outerType
        pure
            ( V.BToNom (ToNom name val')
            , p2_outerType
            )

inferInternal ::
    (Type -> Scope -> a -> b) ->
    Dependencies -> Scope -> Val a -> Infer (Val b)
inferInternal f deps =
    (fmap . fmap) snd . go
    where
        go locals (Ann pl body) =
            ( case body of
              V.BLeaf leaf -> inferLeaf deps leaf
              V.BLam lam -> inferAbs lam
              V.BApp app -> inferApply app
              V.BGetField getField -> inferGetField getField
              V.BInject inject -> inferInject inject
              V.BCase case_ -> inferCase case_
              V.BRecExtend recExtend -> inferRecExtend recExtend
              V.BToNom nom -> inferToNom (deps ^. depsNominals) nom
            ) go locals
            <&> \(body', typ) -> (typ, Ann (f typ locals pl) body')
