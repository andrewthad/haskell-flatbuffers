{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}

module FlatBuffers.Read where
  
import           Control.Exception.Safe        (Exception, MonadThrow, throwM)
import           Data.Binary.Get               (Get)
import qualified Data.Binary.Get               as G
import qualified Data.ByteString               as BS
import           Data.ByteString.Lazy          (ByteString)
import qualified Data.ByteString.Lazy          as BSL
import qualified Data.ByteString.Lazy.Internal as BSL
import           Data.Coerce                   (Coercible, coerce)
import           Data.Functor                  ((<&>))
import           Data.Int
import           Data.Proxy                    (Proxy (..))
import           Data.String                   (IsString)
import           Data.Text                     (Text)
import qualified Data.Text                     as T
import qualified Data.Text.Encoding            as T
import qualified Data.Text.Encoding.Error      as T
import           Data.Word
import           FlatBuffers.Classes           (PrimField (..))
import           HaskellWorks.Data.Int.Widen   (widen16, widen32, widen64)


type ReadCtx m = MonadThrow m

newtype FieldName = FieldName Text
  deriving (Show, Eq, IsString)

newtype Index = Index { unIndex :: Word16 }
  deriving (Show, Num)

newtype VectorLength = VectorLength { unVectorLength :: Word32 }
  deriving (Show, Num, Eq)

newtype VectorIndex = VectorIndex { unVectorIndex :: Word32 }
  deriving (Show, Num, Real, Ord, Enum, Integral, Eq)

newtype VOffset = VOffset { unVOffset :: Word16 }
  deriving (Show, Num, Real, Ord, Enum, Integral, Eq)

newtype UOffset = UOffset { unUOffset :: Word32 }
  deriving (Show, Num, Eq)

newtype OffsetFromRoot = OffsetFromRoot { unOffsetFromRoot :: Word64 }
  deriving (Show, Num, Real, Ord, Enum, Integral, Eq)

data Table = Table
  { vtable   :: !ByteString
  , tablePos :: !Position
  }

newtype Struct = Struct { unStruct :: Position }

data Vector a = Vector
  { vectorLength :: !VectorLength
  , vectorPos    :: !Position
  }

-- | Current position in the buffer
data Position = Position
  { posRoot           :: !ByteString -- ^ Pointer to the buffer root
  , posCurrent        :: !ByteString -- ^ Pointer to current position
  , posOffsetFromRoot :: !OffsetFromRoot -- ^ Number of bytes between current position and root
  }

class HasPosition a where
  getPos :: a -> Position

instance HasPosition Position   where getPos = id
instance HasPosition Table      where getPos = tablePos
instance HasPosition Struct     where getPos = unStruct
instance HasPosition (Vector a) where getPos = vectorPos

class Sized a where
  getInlineSize :: Proxy a -> Word16
  readInline :: ReadCtx m => Position -> m a

instance Sized Text where
  getInlineSize _ = 4
  readInline = readText

instance Sized Table where
  getInlineSize _ = 4
  readInline = readTable

decode :: forall t m. (ReadCtx m, Coercible Table t) => ByteString -> m t
decode root = coerce <$> readTable initialPos
  where
    initialPos = Position root root 0

move :: HasPosition p => p -> VOffset -> Position
move hs offset =
  moveInt64 hs (fromIntegral @VOffset @Int64 offset)

moveInt64 :: HasPosition p => p -> Int64 -> Position
moveInt64 hs offset =
  Position
  { posRoot = posRoot
  , posCurrent = BSL.drop offset posCurrent
  , posOffsetFromRoot = posOffsetFromRoot + fromIntegral @Int64 @OffsetFromRoot offset
  }
  where Position{..} = getPos hs

readElem :: forall m a. (ReadCtx m, Sized a) => VectorIndex -> Vector a -> m a
readElem n vec =
  if unVectorIndex n >= unVectorLength (vectorLength vec)
    then throwM $ VectorIndexOutOfBounds (vectorLength vec) n
    else readInline elemPos
  where
    elemSize = fromIntegral @Word16 @Int64 (getInlineSize (Proxy @a))
    elemOffset = 4 + (fromIntegral @VectorIndex @Int64 n * elemSize)
    elemPos = moveInt64 vec elemOffset

toList :: (ReadCtx m, Sized a) => Vector a -> m [a]
toList vec@Vector{..} =
  traverse (\i -> readElem i vec) [0.. coerce vectorLength - 1]

readVector :: ReadCtx m => Position -> m (Vector a)
readVector Position{..} =
  flip runGetM posCurrent $ do
    uoffset <- moveUOffset
    length <- G.getWord32le
    pure $ Vector
      { vectorLength = VectorLength length
      , vectorPos =
          Position
          { posRoot = posRoot
          , posCurrent = BSL.drop (fromIntegral @Word32 @Int64 uoffset) posCurrent
          , posOffsetFromRoot = posOffsetFromRoot + fromIntegral @Word32 @OffsetFromRoot uoffset
          }
      }

readPrim :: (ReadCtx m, PrimField f) => Position -> m f 
readPrim Position{..} = runGetM getter posCurrent

readText :: ReadCtx m => Position -> m Text
readText Position{..} = do
  bs <- flip runGetM posCurrent $ do
    moveUOffset
    strLength <- G.getWord32le
    G.getByteString $ fromIntegral @Word32 @Int strLength
  case T.decodeUtf8' bs of
    Right t -> pure t
    Left (T.DecodeError msg b) -> throwM $ Utf8DecodingError msg b
    -- The `EncodeError` constructor is deprecated and not used
    -- https://hackage.haskell.org/package/text-1.2.3.1/docs/Data-Text-Encoding-Error.html#t:UnicodeException
    Left _ -> error "the impossible happened"

readStruct :: Position -> Struct
readStruct = Struct

readTable :: ReadCtx m => Position -> m Table
readTable Position{..} =
  flip runGetM posCurrent $ do
    tableOffset <- moveUOffset
    soffset <- G.getInt32le

    let tableOffset64 = fromIntegral @Word32 @Int64 tableOffset
    let tableOffsetFromRoot = tableOffset64 + fromIntegral @_ @Int64 posOffsetFromRoot
    let vtable = BSL.drop (tableOffsetFromRoot - widen64 soffset) posRoot
    let table = BSL.drop tableOffsetFromRoot posRoot
    pure $ Table vtable (Position posRoot table (posOffsetFromRoot + OffsetFromRoot (widen64 tableOffset)))

required :: ReadCtx m => FieldName -> (VOffset -> m a) -> Maybe VOffset -> m a
required _ f (Just vo) = f vo
required fn _ _ = throwM $ MissingField fn

optional :: ReadCtx m => a -> (VOffset -> m a) -> Maybe VOffset -> m a
optional _ f (Just vo) = f vo
optional dflt _ _ = pure dflt

tableIndexToVOffset :: (ReadCtx m, Coercible t Table) => t -> Index -> m (Maybe VOffset)
tableIndexToVOffset a ix =
  flip runGetM vtable $ do
    vtableSize <- G.getWord16le
    let vtableIndex = 4 + (unIndex ix * 2)
    if vtableIndex >= vtableSize
      then pure Nothing
      else do
        G.skip (fromIntegral @Word16 @Int vtableIndex - 2)
        G.getWord16le <&> \case
          0 -> Nothing
          word16 -> Just (VOffset word16)
  where Table{..} = coerce a

moveUOffset :: Get Word32
moveUOffset = do
  uoffset <- G.getWord32le
  G.skip (fromIntegral @Word32 @Int uoffset - 4)
  pure uoffset


data Error
  = ParsingError { position :: G.ByteOffset
                 , msg      :: String }
  | MissingField { fieldName :: FieldName }
  | Utf8DecodingError { msg  :: String
                      , byte :: Maybe Word8 }
  | VectorIndexOutOfBounds VectorLength VectorIndex
  | EnumUnknown { enumName :: String, enumValue :: Word64 }
  | UnionUnknown { unionName :: String, unionValue :: Word8 }
  deriving (Show, Eq)

instance Exception Error

runGetM :: ReadCtx m => Get a -> ByteString -> m a
runGetM get =
  feedAll (G.runGetIncremental get)
  where
    feedAll (G.Done _ _ x) _ = pure x
    feedAll (G.Partial k) lbs = feedAll (k (takeHeadChunk lbs)) (dropHeadChunk lbs)
    feedAll (G.Fail _ pos msg) _ = throwM $ ParsingError pos msg

    takeHeadChunk :: BSL.ByteString -> Maybe BS.ByteString
    takeHeadChunk lbs =
      case lbs of
        (BSL.Chunk bs _) -> Just bs
        _ -> Nothing

    dropHeadChunk :: BSL.ByteString -> BSL.ByteString
    dropHeadChunk lbs =
      case lbs of
        (BSL.Chunk _ lbs') -> lbs'
        _ -> BSL.Empty
        