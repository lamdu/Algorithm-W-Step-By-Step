{-# LANGUAGE DeriveGeneric, DeriveFunctor, DeriveFoldable, DeriveTraversable, EmptyDataDecls, GeneralizedNewtypeDeriving, OverloadedStrings #-}
module Lamdu.Expr.Val
  ( Leaf(..)
  , Body(..), Apply(..), GetField(..), Lam(..), RecExtend(..)
  , Val(..), body, payload
  , Var(..)
  , GlobalId(..)
  ) where

import Control.Applicative ((<$>))
import Control.DeepSeq (NFData(..))
import Control.DeepSeq.Generics (genericRnf)
import Control.Lens (Lens')
import Data.Binary (Binary)
import Data.Foldable (Foldable)
import Data.Monoid (Monoid(..))
import Data.String (IsString(..))
import Data.Traversable (Traversable)
import GHC.Generics (Generic)
import Lamdu.Expr.Identifier (Identifier)
import Lamdu.Expr.Type (Tag)
import Text.PrettyPrint ((<+>), (<>))
import Text.PrettyPrint.HughesPJClass (Pretty(..), PrettyLevel, prettyParen)
import qualified Text.PrettyPrint as PP

newtype Var = Var { vvName :: Identifier }
  deriving (Eq, Ord, Show, NFData, IsString, Pretty, Binary)

newtype GlobalId = GlobalId { globalId :: Identifier }
  deriving (Eq, Ord, Show, NFData, IsString, Pretty, Binary)

data Leaf
  =  VVar Var
  |  VGlobal GlobalId
  |  VHole
  |  VLiteralInteger Integer
  |  VRecEmpty
  deriving (Eq, Ord, Generic, Show)
instance NFData Leaf where rnf = genericRnf
instance Binary Leaf

data Apply expr = Apply
  { _applyFunc :: expr
  , _applyArg :: expr
  } deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
instance NFData exp => NFData (Apply exp) where rnf = genericRnf
instance Binary exp => Binary (Apply exp)

data GetField expr = GetField
  { _getFieldRecord :: expr
  , _getFieldTag :: Tag
  } deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
instance NFData exp => NFData (GetField exp) where rnf = genericRnf
instance Binary exp => Binary (GetField exp)

data Lam expr = Lam
  { _lamParamId :: Var
  , _lamResult :: expr
  } deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
instance NFData exp => NFData (Lam exp) where rnf = genericRnf
instance Binary exp => Binary (Lam exp)

data RecExtend expr = RecExtend
  { _recTag :: Tag
  , _recFieldVal :: expr
  , _recRest :: expr
  } deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
instance NFData exp => NFData (RecExtend exp) where rnf = genericRnf
instance Binary exp => Binary (RecExtend exp)

data Body exp
  =  VApp {-# UNPACK #-}!(Apply exp)
  |  VAbs {-# UNPACK #-}!(Lam exp)
  |  VGetField {-# UNPACK #-}!(GetField exp)
  |  VRecExtend {-# UNPACK #-}!(RecExtend exp)
  |  VLeaf Leaf
  deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
-- NOTE: Careful of Eq, it's not alpha-eq!
instance NFData exp => NFData (Body exp) where rnf = genericRnf
instance Binary exp => Binary (Body exp)

data Val a = Val
  { _valPayload :: a
  , _valBody :: !(Body (Val a))
  } deriving (Eq, Ord, Functor, Foldable, Traversable, Generic, Show)
instance NFData a => NFData (Val a) where rnf = genericRnf
instance Binary a => Binary (Val a)

body :: Lens' (Val a) (Body (Val a))
body f (Val pl b) = Val pl <$> f b

payload :: Lens' (Val a) a
payload f (Val pl b) = (`Val` b) <$> f pl

pPrintPrecBody :: Pretty pl => PrettyLevel -> Rational -> Body (Val pl) -> PP.Doc
pPrintPrecBody lvl prec b =
  case b of
  VLeaf (VVar var)          -> pPrint var
  VLeaf (VGlobal tag)       -> pPrint tag
  VLeaf (VLiteralInteger i) -> pPrint i
  VLeaf VHole               -> PP.text "?"
  VApp (Apply e1 e2)        -> prettyParen (10 < prec) $
                                   pPrintPrec lvl 10 e1 <+> pPrintPrec lvl 11 e2
  VAbs (Lam n e)            -> prettyParen (0 < prec) $
                               PP.char '\\' <> pPrint n <+>
                               PP.text "->" <+>
                               pPrint e
  VGetField (GetField e n)  -> prettyParen (12 < prec) $
                               pPrintPrec lvl 12 e <> PP.char '.' <> pPrint n
  VLeaf VRecEmpty           -> PP.text "V{}"
  VRecExtend
    (RecExtend tag val rest)  -> PP.text "{" <+>
                                 prField <>
                                 PP.comma <+>
                                 pPrint rest <+>
                                 PP.text "}"
    where
      prField = pPrint tag <+> PP.text "=" <+> pPrint val

instance Pretty a => Pretty (Val a) where
  pPrintPrec lvl prec (Val pl b)
    | PP.isEmpty plDoc = pPrintPrecBody lvl prec b
    | otherwise =
      prettyParen (13 < prec) $ mconcat
      [ pPrintPrecBody lvl 14 b, PP.text "{", plDoc, PP.text "}" ]
    where
      plDoc = pPrintPrec lvl 0 pl