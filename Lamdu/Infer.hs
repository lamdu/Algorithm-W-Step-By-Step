{-# LANGUAGE DeriveDataTypeable, DeriveGeneric, OverloadedStrings #-}
module Lamdu.Infer
    ( makeScheme
    , TypeVars(..)
    , Loaded(..)
    , infer
    , Scope, emptyScope, Scope.scopeToTypeMap
    , Payload(..), plScope, plType
    , M.Context, M.initialContext
    , M.InferCtx(..), M.inferCtx, Infer
    , M.freshInferredVarName
    , M.freshInferredVar
    ) where

import           Control.Applicative ((<$), (<$>))
import           Control.DeepSeq (NFData(..))
import           Control.DeepSeq.Generics (genericRnf)
import           Control.Lens (Lens')
import           Control.Lens.Operators
import           Control.Lens.Tuple
import           Data.Binary (Binary)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Monoid ((<>))
import           Data.Traversable (sequenceA)
import           Data.Typeable (Typeable)
import           GHC.Generics (Generic)
import           Lamdu.Expr.Nominal (Nominal(..))
import qualified Lamdu.Expr.Nominal as Nominal
import           Lamdu.Expr.Scheme (Scheme)
import           Lamdu.Expr.Type (Type)
import qualified Lamdu.Expr.Type as T
import           Lamdu.Expr.TypeVars (TypeVars(..))
import qualified Lamdu.Expr.TypeVars as TV
import           Lamdu.Expr.Val (Val(..))
import qualified Lamdu.Expr.Val as V
import qualified Lamdu.Infer.Error as Err
import           Lamdu.Infer.Internal.Monad (Infer)
import qualified Lamdu.Infer.Internal.Monad as M
import           Lamdu.Infer.Internal.Scheme (makeScheme)
import qualified Lamdu.Infer.Internal.Scheme as Scheme
import           Lamdu.Infer.Internal.Scope (Scope, emptyScope)
import qualified Lamdu.Infer.Internal.Scope as Scope
import           Lamdu.Infer.Internal.Subst (CanSubst(..))
import qualified Lamdu.Infer.Internal.Subst as Subst
import           Lamdu.Infer.Internal.Unify (unifyUnsafe)

data Payload = Payload
    { _plType :: Type
    , _plScope :: Scope
    } deriving (Generic, Typeable, Show)
instance NFData Payload where rnf = genericRnf
instance Binary Payload

plType :: Lens' Payload Type
plType f pl = (\t' -> pl { _plType = t' }) <$> f (_plType pl)
{-# INLINE plType #-}

plScope :: Lens' Payload Scope
plScope f pl = (\t' -> pl { _plScope = t' }) <$> f (_plScope pl)
{-# INLINE plScope #-}

instance TV.Free Payload where
    free (Payload typ scope) =
        TV.free typ <> TV.free scope

instance CanSubst Payload where
    apply s (Payload typ scope) =
        Payload (Subst.apply s typ) (Subst.apply s scope)

data Loaded = Loaded
    { loadedGlobalTypes :: Map V.GlobalId Scheme
    , loadedNominals :: Map T.Id Nominal
    }

inferSubst :: Loaded -> Scope -> Val a -> Infer (Scope, Val (Payload, a))
inferSubst loaded rootScope val =
    do
        prevSubst <- M.getSubst
        let rootScope' = Subst.apply prevSubst rootScope
        (inferredVal, s) <- M.listenSubst $ inferInternal mkPayload loaded rootScope' val
        return (rootScope', inferredVal <&> _1 %~ Subst.apply s)
    where
        mkPayload typ scope dat = (Payload typ scope, dat)

-- All accessed global IDs are supposed to be extracted from the
-- expression to build this global scope. This is slightly hacky but
-- much faster than a polymorphic monad underlying the InferCtx monad
-- allowing global access.
-- Use loadInfer for a safer interface
infer :: Loaded -> Scope -> Val a -> Infer (Val (Payload, a))
infer loaded scope val =
    do
        ((scope', val'), results) <- M.listenNoTell $ inferSubst loaded scope val
        M.tell $ results & M.subst %~ Subst.intersect (TV.free scope')
        return val'

data CompositeHasTag p = HasTag | DoesNotHaveTag | MayHaveTag (T.Var (T.Composite p))

hasTag :: T.Tag -> T.Composite p -> CompositeHasTag p
hasTag _ T.CEmpty   = DoesNotHaveTag
hasTag _ (T.CVar v) = MayHaveTag v
hasTag tag (T.CExtend t _ r)
    | tag == t  = HasTag
    | otherwise = hasTag tag r

type InferHandler a b =
    (Scope -> a -> Infer (Type, b)) -> Scope ->
    M.Infer (V.Body b, Type)

{-# INLINE inferLeaf #-}
inferLeaf ::
    Map T.Id Nominal -> Map V.GlobalId Scheme -> V.Leaf -> InferHandler a b
inferLeaf nominals globals leaf = \_go locals ->
    case leaf of
    V.LHole -> M.freshInferredVar "h"
    V.LVar n ->
        case Scope.lookupTypeOf n locals of
        Nothing      -> M.throwError $ Err.UnboundVariable n
        Just t       -> return t
    V.LGlobal n ->
        case Map.lookup n globals of
        Nothing      -> M.throwError $ Err.MissingGlobal n
        Just sigma   -> Scheme.instantiate sigma
    V.LLiteralInteger _ -> return T.TInt
    V.LRecEmpty -> return $ T.TRecord T.CEmpty
    V.LAbsurd ->
        do
            tv <- M.freshInferredVar "a"
            return $ T.TFun (T.TSum T.CEmpty) tv
    V.LToNom tid -> inferToNom nominals tid
    V.LFromNom tid -> inferFromNom nominals tid
    V.LInject tag -> inferInject tag
    V.LGetField tag -> inferGetField tag
    <&> (,) (V.BLeaf leaf)

{-# INLINE inferAbs #-}
inferAbs :: V.Lam a -> InferHandler a b
inferAbs (V.Lam n e) = \go locals ->
    do
        tv <- M.freshInferredVar "a"
        let locals' = Scope.insertTypeOf n tv locals
        ((t1, e'), s1) <- M.listenSubst $ go locals' e
        return (V.BAbs (V.Lam n e'), T.TFun (Subst.apply s1 tv) t1)

{-# INLINE inferApply #-}
inferApply :: V.Apply a -> InferHandler a b
inferApply (V.Apply e1 e2) = \go locals ->
    do
        ((p1_t1, e1'), p1_s) <- M.listenSubst $ go locals e1
        let p1 = Subst.apply p1_s

        ((p2_t2, e2'), p2_s) <- M.listenSubst $ go (p1 locals) e2
        let p2_t1 = Subst.apply p2_s p1_t1
        p2_tv <- M.freshInferredVar "a"

        ((), p3_s) <- M.listenSubst $ unifyUnsafe p2_t1 (T.TFun p2_t2 p2_tv)
        let p3_tv = Subst.apply p3_s p2_tv
        return (V.BApp (V.Apply e1' e2'), p3_tv)

{-# INLINE inferGetField #-}
inferGetField :: T.Tag -> Infer Type
inferGetField tag =
    do
        tv <- M.freshInferredVar "a"
        tvRecName <- M.freshInferredVarName "r"
        M.tellProductConstraint tvRecName tag
        return $ T.TFun (T.TRecord (T.CExtend tag tv (TV.lift tvRecName))) tv

{-# INLINE inferInject #-}
inferInject :: T.Tag -> Infer Type
inferInject tag =
    do
        tv <- M.freshInferredVar "a"
        tvSumName <- M.freshInferredVarName "s"
        M.tellSumConstraint tvSumName tag
        return $ T.TFun tv $ T.TSum $ T.CExtend tag tv $ TV.lift tvSumName

{-# INLINE inferCase #-}
inferCase :: V.Case a -> InferHandler a b
inferCase (V.Case name m mm) = \go locals ->
    do
        ((p1_tm, m'), p1_s) <- M.listenSubst $ go locals m
        let p1 = Subst.apply p1_s
        -- p1
        ((p2_tmm, mm'), p2_s) <- M.listenSubst $ go (p1 locals) mm
        let p2 = Subst.apply p2_s
            p2_tm = p2 p1_tm
        -- p2
        p2_tv <- M.freshInferredVar "a"
        p2_tvRes <- M.freshInferredVar "res"
        -- type(match) `unify` a->res
        ((), p3_s) <-
            M.listenSubst $ unifyUnsafe p2_tm $ T.TFun p2_tv p2_tvRes
        let p3 x = Subst.apply p3_s x
            p3_tv    = p3 p2_tv
            p3_tvRes = p3 p2_tvRes
            p3_tmm   = p3 p2_tmm
        -- p3
        -- new sum type var "s":
        tvSumName <- M.freshInferredVarName "s"
        M.tellSumConstraint tvSumName name
        let p3_tvSum = TV.lift tvSumName
        -- type(mismatch) `unify` [ s ]->res
        ((), p4_s) <-
            M.listenSubst $ unifyUnsafe p3_tmm $
            T.TFun (T.TSum p3_tvSum) p3_tvRes
        let p4 x = Subst.apply p4_s x
            p4_tvSum = p4 p3_tvSum
            p4_tvRes = p4 p3_tvRes
            p4_tv    = p4 p3_tv
        -- p4
        return
            ( V.BCase (V.Case name m' mm')
            , T.TFun (T.TSum (T.CExtend name p4_tv p4_tvSum)) p4_tvRes
            )

{-# INLINE inferRecExtend #-}
inferRecExtend :: V.RecExtend a -> InferHandler a b
inferRecExtend (V.RecExtend name e1 e2) = \go locals ->
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
                DoesNotHaveTag -> return x
                MayHaveTag var -> x <$ M.tellProductConstraint var name
            _ -> do
                tv <- M.freshInferredVarName "r"
                M.tellProductConstraint tv name
                let tve = TV.lift tv
                ((), s) <- M.listenSubst $ unifyUnsafe t2 $ T.TRecord tve
                return $ Subst.apply s tve
        let t1' = Subst.apply s3 $ Subst.apply s2 t1
        return
            ( V.BRecExtend (V.RecExtend name e1' e2')
            , T.TRecord $ T.CExtend name t1' rest
            )

getNominal :: Map T.Id Nominal -> T.Id -> M.Infer Nominal
getNominal nominals name =
    case Map.lookup name nominals of
    Nothing -> M.throwError $ Err.MissingNominal name
    Just nominal -> return nominal

nomTypes :: Map T.Id Nominal -> T.Id -> M.Infer (Type, Type)
nomTypes nominals name =
    do
        nominal <- getNominal nominals name
        p1_paramVals <-
            nParams nominal
            & Map.keysSet & Map.fromSet (const (M.freshInferredVar "n"))
            & sequenceA
        p1_freshInnerType <-
            Nominal.apply p1_paramVals nominal & Scheme.instantiate
        return (T.TInst name p1_paramVals, p1_freshInnerType)

inferFromNom :: Map T.Id Nominal -> T.Id -> Infer Type
inferFromNom nominals name =
    do
        (p1_outerType, p1_innerType) <- nomTypes nominals name
        return $ T.TFun p1_outerType p1_innerType

inferToNom :: Map T.Id Nominal -> T.Id -> Infer Type
inferToNom nominals name =
    do
        (p1_outerType, p1_innerType) <- nomTypes nominals name
        return $ T.TFun p1_innerType p1_outerType

inferInternal ::
    (Type -> Scope -> a -> b) ->
    Loaded -> Scope -> Val a -> Infer (Val b)
inferInternal f loaded =
    (fmap . fmap) snd . go
    where
        go locals (Val pl body) =
            ( case body of
              V.BLeaf l ->
                inferLeaf (loadedNominals loaded) (loadedGlobalTypes loaded) l
              V.BAbs lam -> inferAbs lam
              V.BApp app -> inferApply app
              V.BCase case_ -> inferCase case_
              V.BRecExtend recExtend -> inferRecExtend recExtend
            ) go locals
            <&> \(body', typ) -> (typ, Val (f typ locals pl) body')
