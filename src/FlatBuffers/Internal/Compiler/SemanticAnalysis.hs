{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ConstraintKinds     #-}
{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

module FlatBuffers.Internal.Compiler.SemanticAnalysis where

import           Control.Applicative                      ((<|>))
import           Control.Monad                            (forM_, when)
import           Control.Monad.Except                     (MonadError,
                                                           throwError)
import           Control.Monad.Reader                     (runReaderT)
import           Control.Monad.Reader.Class               (MonadReader (..))
import           Control.Monad.State                      (State, evalState,
                                                           execStateT, get,
                                                           modify, put)
import           Control.Monad.State.Class                (MonadState)
import           Data.Coerce                              (coerce)
import           Data.Foldable                            (find, maximum,
                                                           traverse_)
import           Data.Functor                             ((<&>))
import           Data.Int
import           Data.Ix                                  (inRange)
import qualified Data.List                                as List
import           Data.List.NonEmpty                       (NonEmpty ((:|)))
import qualified Data.List.NonEmpty                       as NE
import           Data.Map.Strict                          (Map)
import qualified Data.Map.Strict                          as Map
import           Data.Maybe                               (fromMaybe)
import           Data.Monoid                              (Sum (..))
import           Data.Text                                (Text)
import qualified Data.Text                                as T
import qualified Data.Tree                                as Tree
import           Data.Word
import           FlatBuffers.Constants                    (InlineSize (..))
import           FlatBuffers.Internal.Compiler.SyntaxTree (Ident, Namespace,
                                                           Schema, qualify)
import qualified FlatBuffers.Internal.Compiler.SyntaxTree as ST
import           FlatBuffers.Internal.Util                (Display (..),
                                                           isPowerOfTwo)

-- |  The identifier in the reader environment represents the validation context,
-- the thing being validated (e.g. a struct name, or a table field).
type ValidationCtx m = (MonadError Text m, MonadReader Ident m)

type Required = Bool

newtype DefaultVal a = DefaultVal (Maybe a)

-- | Unvalidated type declarations, paired with their respective namespaces
data DeclsWithNamespace = DeclsWithNamespace
  { tables  :: [(Namespace, ST.TableDecl)]
  , structs :: [(Namespace, ST.StructDecl)]
  , enums   :: [(Namespace, ST.EnumDecl)]
  , unions  :: [(Namespace, ST.UnionDecl)]
  }

instance Semigroup DeclsWithNamespace where
  DeclsWithNamespace t1 s1 e1 u1 <> DeclsWithNamespace t2 s2 e2 u2 =
    DeclsWithNamespace (t1 <> t2) (s1 <> s2) (e1 <> e2) (u1 <> u2)

instance Monoid DeclsWithNamespace where
  mempty = DeclsWithNamespace [] [] [] []

-- | Semantically valid type declarations
data ValidDecls = ValidDecls
  { validEnums   :: [EnumDecl]
  , validStructs :: [StructDecl]
  } deriving (Show, Eq)

instance Semigroup ValidDecls where
  ValidDecls e1 s1 <> ValidDecls e2 s2 =
    ValidDecls (e1 <> e2) (s1 <> s2)

instance Monoid ValidDecls where
  mempty = ValidDecls [] []

-- | Takes a collection of schemas, and pairs each type declaration with its corresponding namespace
pairDeclsWithNamespaces :: Tree.Tree Schema -> DeclsWithNamespace
pairDeclsWithNamespaces = foldMap (pairDeclsWithNamespaces' . ST.decls)
  where
    pairDeclsWithNamespaces' :: [ST.Decl] -> DeclsWithNamespace
    pairDeclsWithNamespaces' = snd . foldl go ("", mempty)

    go :: (Namespace, DeclsWithNamespace) -> ST.Decl -> (Namespace, DeclsWithNamespace)
    go (currentNamespace, decls) decl =
      case decl of
        ST.DeclN (ST.NamespaceDecl newNamespace) -> (newNamespace, decls)
        ST.DeclT table  -> (currentNamespace, decls <> DeclsWithNamespace [(currentNamespace, table)] [] [] [])
        ST.DeclS struct -> (currentNamespace, decls <> DeclsWithNamespace [] [(currentNamespace, struct)] [] [])
        ST.DeclE enum   -> (currentNamespace, decls <> DeclsWithNamespace [] [] [(currentNamespace, enum)] [])
        ST.DeclU union  -> (currentNamespace, decls <> DeclsWithNamespace [] [] [] [(currentNamespace, union)])
        _               -> (currentNamespace, decls)


validateDecls :: MonadError Text m => DeclsWithNamespace -> m ValidDecls
validateDecls decls = flip runReaderT "" $ do
  validEnums <- validateEnums (enums decls)
  validStructs <- validateStructs validEnums (structs decls)

  pure $ ValidDecls
    { validEnums = validEnums
    , validStructs = validStructs
    }


data EnumDecl = EnumDecl
  { enumNamespace :: Namespace
  , enumIdent     :: Ident
  , enumType      :: EnumType
  , enumVals      :: NonEmpty EnumVal
  } deriving (Show, Eq)

data EnumVal = EnumVal
  { enumValIdent :: Ident
  , enumValInt   :: Integer
  } deriving (Show, Eq)

data EnumType
  = EInt8
  | EInt16
  | EInt32
  | EInt64
  | EWord8
  | EWord16
  | EWord32
  | EWord64
  deriving (Show, Eq)

validateEnums :: forall m. ValidationCtx m => [(Namespace, ST.EnumDecl)] -> m [EnumDecl]
validateEnums = traverse validateEnum

-- TODO: add support for `bit_flags` attribute
validateEnum :: forall m. ValidationCtx m => (Namespace, ST.EnumDecl) -> m EnumDecl
validateEnum (currentNamespace, enum) =
  local (\_ -> qualify currentNamespace (ST.enumIdent enum)) $
    checkBitFlags >> checkDuplicateFields >> validEnum
  where
    validEnum = do
      enumType <- validateEnumType (ST.enumType enum)
      let enumVals = flip evalState Nothing . traverse mapEnumVal $ ST.enumVals enum
      validateOrder enumVals
      traverse_ (validateBounds enumType) enumVals
      pure EnumDecl
        { enumNamespace = currentNamespace
        , enumIdent = ST.enumIdent enum
        , enumType = enumType
        , enumVals = enumVals
        }

    mapEnumVal :: ST.EnumVal -> State (Maybe Integer) EnumVal
    mapEnumVal enumVal = do
      thisInt <-
        case ST.enumValLiteral enumVal of
          Just (ST.IntLiteral thisInt) ->
            pure thisInt
          Nothing ->
            get <&> \case
              Just lastInt -> lastInt + 1
              Nothing      -> 0
      put (Just thisInt)
      pure (EnumVal (ST.enumValIdent enumVal) thisInt)

    validateOrder :: NonEmpty EnumVal -> m ()
    validateOrder xs =
      if all (\(x, y) -> enumValInt x < enumValInt y) (NE.toList xs `zip` NE.tail xs)
        then pure ()
        else throwErrorMsg "enum values must be specified in ascending order"

    validateBounds :: EnumType -> EnumVal -> m ()
    validateBounds enumType enumVal =
      case enumType of
        EInt8 -> validateBounds' @Int8 enumVal
        EInt16 -> validateBounds' @Int16 enumVal
        EInt32 -> validateBounds' @Int32 enumVal
        EInt64 -> validateBounds' @Int64 enumVal
        EWord8 -> validateBounds' @Word8 enumVal
        EWord16 -> validateBounds' @Word16 enumVal
        EWord32 -> validateBounds' @Word32 enumVal
        EWord64 -> validateBounds' @Word64 enumVal

    validateBounds' :: forall a. (Integral a, Bounded a, Show a) => EnumVal -> m ()
    validateBounds' e =
      if inRange (toInteger (minBound @a), toInteger (maxBound @a)) (enumValInt e)
        then pure ()
        else throwErrorMsg $
              "enum value does not fit ["
              <> T.pack (show (minBound @a))
              <> "; "
              <> T.pack (show (maxBound @a))
              <> "]"

    validateEnumType :: ST.Type -> m EnumType
    validateEnumType t =
      case t of
        ST.TInt8 -> pure EInt8
        ST.TInt16 -> pure EInt16
        ST.TInt32 -> pure EInt32
        ST.TInt64 -> pure EInt64
        ST.TWord8 -> pure EWord8
        ST.TWord16 -> pure EWord16
        ST.TWord32 -> pure EWord32
        ST.TWord64 -> pure EWord64
        _          -> throwErrorMsg "underlying enum type must be integral"

    checkDuplicateFields :: m ()
    checkDuplicateFields =
      checkDuplicateIdentifiers
        (coerce . ST.enumValIdent <$> ST.enumVals enum)

    checkBitFlags :: m ()
    checkBitFlags =
      when (hasAttribute "bit_flags" (ST.enumMetadata enum)) $
        throwErrorMsg "`bit_flags` are not supported yet"

checkDuplicateIdentifiers :: (ValidationCtx m, Foldable f, Functor f) => f Text -> m ()
checkDuplicateIdentifiers idents =
  case findDups idents of
    [] -> pure ()
    dups ->
      throwErrorMsg $
      "["
      <> T.intercalate ", " dups
      <> "] declared more than once"

findDups :: (Foldable f, Functor f, Ord a) => f a -> [a]
findDups xs = Map.keys $ Map.filter (>1) $ occurrences xs

occurrences :: (Foldable f, Functor f, Ord a) => f a -> Map a (Sum Int)
occurrences xs =
  Map.unionsWith (<>) $ fmap (\x -> Map.singleton x (Sum 1)) xs

hasAttribute :: Text -> ST.Metadata -> Bool
hasAttribute name (ST.Metadata attrs) = Map.member name attrs

findIntAttr :: ValidationCtx m => Text -> ST.Metadata -> m (Maybe Integer)
findIntAttr name (ST.Metadata attrs) =
  case Map.lookup name attrs of
    Nothing                  -> pure Nothing
    Just (Just (ST.AttrI i)) -> pure (Just i)
    Just _ ->
      throwErrorMsg $
        "expected attribute '"
        <> name
        <> "' to have an integer value, e.g. '"
        <> name
        <> ": 123'"

findStringAttr :: ValidationCtx m => Text -> ST.Metadata -> m (Maybe Text)
findStringAttr name (ST.Metadata attrs) =
  case Map.lookup name attrs of
    Nothing                  -> pure Nothing
    Just (Just (ST.AttrS s)) -> pure (Just s)
    Just _ ->
      throwErrorMsg $
        "expected attribute '"
        <> name
        <> "' to have a string value, e.g. '"
        <> name
        <> ": \"abc\"'"

data TableDecl = TableDecl
  { tableIdent     :: Ident
  , tableNamespace :: Ident
  , tableFields    :: NonEmpty TableField
  }

data TableField = TableField
  { tableFieldType       :: TableFieldType
  , tableFieldDeprecated :: Bool
  , tableFieldId         :: Maybe Int
  }

data TableFieldType
  = TInt8 (DefaultVal Int8)
  | TInt16 (DefaultVal Int16)
  | TInt32 (DefaultVal Int32)
  | TInt64 (DefaultVal Int64)
  | TWord8 (DefaultVal Word8)
  | TWord16 (DefaultVal Word16)
  | TWord32 (DefaultVal Word32)
  | TWord64 (DefaultVal Word64)
  | TFloat (DefaultVal Float)
  | TDouble (DefaultVal Double)
  | TBool (DefaultVal Bool)
  | TEnum (DefaultVal Ident) Ident
  | TStruct Required Ident
  | TTable Required Ident
  | TUnion Required Ident
  | TString Required
  | TVector Required VectorElementType

data VectorElementType
  = VInt8
  | VInt16
  | VInt32
  | VInt64
  | VWord8
  | VWord16
  | VWord32
  | VWord64
  | VFloat
  | VDouble
  | VBool
  | VEnum Ident InlineSize
  | VStruct Ident InlineSize
  | VTable Ident
  | VUnion Ident
  | VString

data StructDecl = StructDecl
  { structNamespace  :: Namespace
  , structIdent      :: Ident
  , structAlignment  :: Word8 -- [1, 16]
  , structFields     :: NonEmpty StructField
  } deriving (Show, Eq)

data StructField = StructField
  { structFieldIdent :: Ident
  , structFieldType  :: StructFieldType
  } deriving (Show, Eq)

data StructFieldType
  = SInt8
  | SInt16
  | SInt32
  | SInt64
  | SWord8
  | SWord16
  | SWord32
  | SWord64
  | SFloat
  | SDouble
  | SBool
  | SEnum
      Namespace -- ^ The namespace of the enum that this field refers to
      Ident     -- ^ The name of the enum that this field refers to
      EnumType
  | SStruct StructDecl
  deriving (Show, Eq)

validateStructs :: ValidationCtx m => [EnumDecl] -> [(Namespace, ST.StructDecl)] -> m [StructDecl]
validateStructs validEnums structs = do
  traverse_ (checkStructCycles structs) structs
  flip execStateT [] $ traverse (validateStruct validEnums structs) structs

checkStructCycles :: forall m. ValidationCtx m => [(Namespace, ST.StructDecl)] -> (Namespace, ST.StructDecl) -> m ()
checkStructCycles structs = go []
  where
    go :: [Ident] -> (Namespace, ST.StructDecl) -> m ()
    go visited (currentNamespace, struct) =
      let qualifiedName = qualify currentNamespace (ST.structIdent struct)
      in  local (const qualifiedName) $
            if qualifiedName `elem` visited
              then
                throwErrorMsg $
                  "cyclic dependency detected ["
                  <> display (T.intercalate " -> " . coerce $ List.dropWhile (/= qualifiedName) $ List.reverse (qualifiedName : visited))
                  <>"] - structs cannot contain themselves, directly or indirectly"
              else
                forM_ (ST.structFields struct) $ \field ->
                  case ST.structFieldType field of
                    ST.TRef typeRef ->
                      case findDecl currentNamespace structs fst (ST.structIdent . snd) typeRef of
                        Right struct ->
                          go (qualifiedName : visited) struct
                        Left _ ->
                          pure () -- The TypeRef points to an enum (or is invalid), so no further validation is needed at this point
                    _ -> pure () -- Field is not a TypeRef, no validation needed

validateStruct ::
     forall m. (MonadState [StructDecl] m, ValidationCtx m)
  => [EnumDecl]
  -> [(Namespace, ST.StructDecl)]
  -> (Namespace, ST.StructDecl)
  -> m StructDecl
validateStruct validEnums structs (currentNamespace, struct) =
  local (\_ -> qualify currentNamespace (ST.structIdent struct)) $ do
    validStructs <- get
    -- Check if this struct has already been validated in a previous iteration
    case find (\s -> structNamespace s == currentNamespace && structIdent s == ST.structIdent struct) validStructs of
      Just match -> pure match
      Nothing -> do
        checkDuplicateFields

        fields <- traverse validateStructField (ST.structFields struct)
        let naturalAlignment = maximum (structFieldAlignment <$> fields)
        forceAlignAttr <- getForceAlignAttr
        forceAlign <- traverse (validateForceAlign naturalAlignment) forceAlignAttr
        let alignment = fromMaybe naturalAlignment forceAlign

        let validStruct = StructDecl
              { structNamespace  = currentNamespace
              , structIdent      = ST.structIdent struct
              , structAlignment  = alignment
              , structFields     = fields
              }
        modify (validStruct :)
        pure validStruct

  where
    invalidStructFieldType = "struct fields may only be integers, floating point, bool, enums, or other structs"

    validateStructField :: ST.StructField -> m StructField
    validateStructField sf =
      local (\context -> context <> "." <> ST.structFieldIdent sf) $ do
        checkDeprecated sf
        structFieldType <- validateStructFieldType (ST.structFieldType sf)
        pure $ StructField
          { structFieldIdent = ST.structFieldIdent sf
          , structFieldType = structFieldType
          }

    validateStructFieldType :: ST.Type -> m StructFieldType
    validateStructFieldType structFieldType =
      case structFieldType of
        ST.TInt8 -> pure SInt8
        ST.TInt16 -> pure SInt16
        ST.TInt32 -> pure SInt32
        ST.TInt64 -> pure SInt64
        ST.TWord8 -> pure SWord8
        ST.TWord16 -> pure SWord16
        ST.TWord32 -> pure SWord32
        ST.TWord64 -> pure SWord64
        ST.TFloat -> pure SFloat
        ST.TDouble -> pure SDouble
        ST.TBool -> pure SBool
        ST.TString -> throwErrorMsg invalidStructFieldType
        ST.TVector _ -> throwErrorMsg invalidStructFieldType
        ST.TRef typeRef ->
          -- check if this is a reference to an enum
          case findDecl currentNamespace validEnums enumNamespace enumIdent typeRef of
            Right enum -> pure (SEnum (enumNamespace enum) (enumIdent enum) (enumType enum))
            Left _ ->
              -- check if this is a reference to a struct, and validate it
              case findDecl currentNamespace structs fst (ST.structIdent . snd) typeRef of
                Right (nestedNamespace, nestedStruct) ->
                  SStruct <$> validateStruct validEnums structs (nestedNamespace, nestedStruct)
                Left checkedNamespaces ->
                  throwErrorMsg $
                    "type '"
                    <> display typeRef
                    <> "' does not exist (checked in these namespaces: "
                    <> display checkedNamespaces
                    <> ") or is not allowed in a struct field"
                    <> " ("
                    <> invalidStructFieldType
                    <> ")"

    checkDeprecated :: ST.StructField -> m ()
    checkDeprecated structField =
      when (hasAttribute "deprecated" (ST.structFieldMetadata structField)) $
        throwErrorMsg "can't deprecate fields in a struct"

    getForceAlignAttr :: m (Maybe Integer)
    getForceAlignAttr = findIntAttr "force_align" (ST.structMetadata struct)

    validateForceAlign :: Word8 -> Integer -> m Word8
    validateForceAlign naturalAlignment forceAlign =
      if isPowerOfTwo forceAlign
        && inRange (fromIntegral @Word8 @Integer naturalAlignment, 16) forceAlign
        then pure (fromIntegral @Integer @Word8 forceAlign)
        else throwErrorMsg $
              "force_align must be a power of two integer ranging from the struct's natural alignment (in this case, "
              <> T.pack (show naturalAlignment)
              <> ") to 16"

    checkDuplicateFields :: m ()
    checkDuplicateFields =
      checkDuplicateIdentifiers
        (coerce . ST.structFieldIdent <$> ST.structFields struct)

structFieldAlignment :: StructField -> Word8
structFieldAlignment sf =
  case structFieldType sf of
    SInt8 -> 1
    SInt16 -> 2
    SInt32 -> 4
    SInt64 -> 8
    SWord8 -> 1
    SWord16 -> 2
    SWord32 -> 4
    SWord64 -> 8
    SFloat -> 4
    SDouble -> 8
    SBool -> 1
    SEnum _ _ enumType -> enumAlignment enumType
    SStruct nestedStruct -> structAlignment nestedStruct

-- | The size of an enum is either 1, 2, 4 or 8 bytes, so its size fits in a Word8
enumSize :: EnumType -> Word8
enumSize e =
  case e of
    EInt8 -> 1
    EInt16 -> 2
    EInt32 -> 3
    EInt64 -> 4
    EWord8 -> 1
    EWord16 -> 2
    EWord32 -> 3
    EWord64 -> 4

enumAlignment :: EnumType -> Word8
enumAlignment = enumSize

-- | Returns a list of all the namespaces "between" the current namespace
-- and the root namespace, in that order.
-- See: https://github.com/google/flatbuffers/issues/5234#issuecomment-471680403
-- 
-- > parentNamespaces "A.B.C" == ["A.B.C", "A.B", "A", ""]
parentNamespaces :: ST.Namespace -> NonEmpty ST.Namespace
parentNamespaces (ST.Namespace ns) =
  coerce $ NE.reverse $ NE.inits ns
  

-- | Looks for a type reference in a set of type declarations.
-- If none is found, the list of namespaces in which the type reference was searched for is return.
findDecl ::
     Namespace
  -> [decl]
  -> (decl -> Namespace)
  -> (decl -> Ident)
  -> ST.TypeRef
  -> Either (NonEmpty Namespace) decl
findDecl currentNamespace decls getNamespace getIdent (ST.TypeRef refNamespace refIdent) =
  let parentNamespaces' = parentNamespaces currentNamespace
      results = do
        parentNamespace <- parentNamespaces'
        let candidateNamespace = parentNamespace <> refNamespace
        pure $ find (\decl -> getNamespace decl == candidateNamespace && getIdent decl == refIdent) decls
  in  
    case foldl1 (<|>) results of
      Just match -> Right match
      Nothing    -> Left parentNamespaces'

enumQualifiedName :: EnumDecl -> Ident
enumQualifiedName e = qualify (enumNamespace e) (enumIdent e)

structQualifiedName :: StructDecl -> Ident
structQualifiedName s = qualify (structNamespace s) (structIdent s)


throwErrorMsg :: ValidationCtx m => Text -> m a
throwErrorMsg msg = do
  context <- ask
  throwError $ "[" <> display context <> "]: " <> msg

