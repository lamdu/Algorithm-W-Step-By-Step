{-# LANGUAGE DeriveGeneric #-}
module Lamdu.Infer.Internal.TypeVars
  ( TypeVars(..)
  , HasVar(..), CompositeHasVar
  , difference
  ) where

import Control.DeepSeq (NFData(..))
import Control.DeepSeq.Generics (genericRnf)
import Data.Monoid (Monoid(..))
import Data.Set (Set)
import GHC.Generics (Generic)
import qualified Data.Set as Set
import qualified Lamdu.Expr as E

data TypeVars = TypeVars (Set (E.TypeVar E.Type)) (Set (E.TypeVar E.ProductType))
  deriving (Eq, Generic)
instance NFData TypeVars where
  rnf = genericRnf
instance Monoid TypeVars where
  mempty = TypeVars mempty mempty
  mappend (TypeVars t0 r0) (TypeVars t1 r1) =
    TypeVars (mappend t0 t1) (mappend r0 r1)

class HasVar t where
  getVars :: TypeVars -> Set (E.TypeVar t)
  newVars :: Set (E.TypeVar t) -> TypeVars
  liftVar :: E.TypeVar t -> t

instance HasVar E.Type where
  getVars (TypeVars vs _) = vs
  newVars vs = TypeVars vs mempty
  liftVar = E.TVar

class CompositeHasVar p where
  compositeGetVars :: TypeVars -> Set (E.TypeVar (E.CompositeType p))
  compositeNewVars :: Set (E.TypeVar (E.CompositeType p)) -> TypeVars

instance CompositeHasVar E.Product where
  compositeGetVars (TypeVars _ vs) = vs
  compositeNewVars vs = TypeVars mempty vs

instance CompositeHasVar p => HasVar (E.CompositeType p) where
  getVars = compositeGetVars
  newVars = compositeNewVars
  liftVar = E.CVar

difference :: TypeVars -> TypeVars -> TypeVars
difference (TypeVars t0 r0) (TypeVars t1 r1) =
  TypeVars (Set.difference t0 t1) (Set.difference r0 r1)
