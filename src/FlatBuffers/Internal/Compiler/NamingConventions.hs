{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ViewPatterns #-}

module FlatBuffers.Internal.Compiler.NamingConventions where

import           Data.Text                                     ( Text )
import qualified Data.Text                                     as T
import qualified Data.Text.Manipulate                          as TM

import           FlatBuffers.Internal.Compiler.ValidSyntaxTree ( EnumDecl, HasIdent(..), Ident(..), Namespace(..), TableField, TypeRef(..), UnionDecl )


-- Style guide: https://google.github.io/flatbuffers/flatbuffers_guide_writing_schema.html

dataTypeConstructor :: Text -> Text
dataTypeConstructor = TM.toCamel

arg :: Text -> Text
arg = TM.toCamel

dataTypeName :: Text -> Text
dataTypeName = TM.toPascal

namespace :: Namespace -> Text
namespace (Namespace fragments) = T.intercalate "." (TM.toPascal <$> fragments)

getter :: (HasIdent parent, HasIdent field) => parent -> field -> Text
getter (getIdent -> unIdent -> parent) (getIdent -> unIdent -> field) =
  TM.toCamel parent <> TM.toPascal field

toEnumFun :: EnumDecl -> Text
toEnumFun enum =
  "to" <> TM.toPascal (unIdent (getIdent enum))

fromEnumFun :: EnumDecl -> Text
fromEnumFun enum =
  "from" <> TM.toPascal (unIdent (getIdent enum))

enumUnionMember :: (HasIdent parent, HasIdent val) => parent -> val -> Text
enumUnionMember (getIdent -> unIdent -> parentIdent) (getIdent -> unIdent -> valIdent) =
  TM.toPascal parentIdent <> TM.toPascal valIdent

unionClass :: UnionDecl -> Text
unionClass (getIdent -> unIdent -> unionIdent) =
  "Write" <> TM.toPascal unionIdent

readUnionFun :: HasIdent union => union -> Text
readUnionFun (getIdent -> unIdent -> unionIdent) =
  "read" <> TM.toPascal unionIdent

unionVecArg :: TableField -> (Text, Text)
unionVecArg tf =
  let argName = arg (unIdent (getIdent tf))
  in  (argName <> "Types", argName <> "Values")


withModulePrefix :: Namespace -> Text -> Text
withModulePrefix ns text =
  if ns == ""
    then text
    else namespace ns <> "." <> text

