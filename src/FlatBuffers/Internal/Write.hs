{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MagicHash #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UnliftedFFITypes #-}

module FlatBuffers.Internal.Write where

import           Control.Monad.State.Strict

import           Data.ByteString.Builder             ( Builder )
import qualified Data.ByteString.Builder             as B
import qualified Data.ByteString.Lazy                as BSL
import           Data.Coerce                         ( coerce )
import qualified Data.Foldable                       as Foldable
import           Data.Int
import qualified Data.List                           as L
import qualified Data.Map.Strict                     as M
import           Data.Monoid                         ( Sum(..) )
import           Data.Semigroup                      ( Max(..) )
import           Data.Text                           ( Text )
import qualified Data.Text.Array                     as A
import qualified Data.Text.Encoding                  as T
import qualified Data.Text.Internal                  as TI
import           Data.Word

import           FlatBuffers.Internal.Build
import           FlatBuffers.Internal.Constants
import           FlatBuffers.Internal.FileIdentifier ( FileIdentifier(unFileIdentifier), HasFileIdentifier(getFileIdentifier) )
import           FlatBuffers.Internal.Types

import           Foreign.C.Types                     ( CSize(CSize) )

import           GHC.Base                            ( ByteArray# )

import           System.IO.Unsafe                    ( unsafeDupablePerformIO )


type BufferSize = Sum Int32

-- | The position of something in a buffer, expressed as the number of bytes counting from the end.
type Position = Int32

data FBState = FBState
  { builder      :: !Builder
  , bufferSize   :: {-# UNPACK #-} !BufferSize
  , maxAlign     :: {-# UNPACK #-} !(Max Alignment)
  , cache        :: !(M.Map BSL.ByteString Position)
  }

newtype WriteTableField = WriteTableField { unWriteTableField :: State FBState (FBState -> FBState) }

newtype WriteStruct a = WriteStruct { buildStruct :: Builder }

newtype WriteTable a = WriteTable (State FBState Position)

data WriteUnion a
  = Some
      {-# UNPACK #-} !Word8
      !(State FBState Position)
  | None


{-# INLINE encode #-}
encode :: WriteTable a -> BSL.ByteString
encode = encodeState (FBState mempty (Sum 0) (Max 1) mempty)

{-# INLINE encodeState #-}
encodeState :: FBState -> WriteTable a -> BSL.ByteString
encodeState state (WriteTable writeTable) =
  B.toLazyByteString $
  builder $
  execState
    (do pos <- writeTable
        maxAlignment <- gets (getMax . maxAlign)
        modify' $ alignTo maxAlignment uoffsetSize
        modify' $ uoffsetFrom pos
    )
    state

{-# INLINE encodeWithFileIdentifier #-}
encodeWithFileIdentifier :: forall a. HasFileIdentifier a => WriteTable a -> BSL.ByteString
encodeWithFileIdentifier =
  encodeStateWithFileIdentifier (FBState mempty (Sum 0) (Max 1) mempty) (getFileIdentifier @a)

{-# INLINE encodeStateWithFileIdentifier #-}
encodeStateWithFileIdentifier :: FBState -> FileIdentifier -> WriteTable a -> BSL.ByteString
encodeStateWithFileIdentifier state fi (WriteTable writeTable) =
  B.toLazyByteString $
  builder $
  execState
    (do pos <- writeTable
        maxAlignment <- gets (getMax . maxAlign)
        modify' $ alignTo maxAlignment (uoffsetSize + fileIdentifierSize)
        modify' $ writeFileIdentifier fi
        modify' $ uoffsetFrom pos
    )
    state


-- | Writes something (unaligned) to the buffer.
{-# INLINE write #-}
write :: Int32 -> Builder -> FBState -> FBState
write bsize b fbs = fbs
  { builder = b <> builder fbs
  , bufferSize = bufferSize fbs <> Sum bsize
  }

-- | Writes a 32-bit int (unaligned) to the buffer.
{-# INLINE writeInt32 #-}
writeInt32 :: Int32 -> FBState -> FBState
writeInt32 n = write int32Size (B.int32LE n)

{-# INLINE writeFileIdentifier #-}
writeFileIdentifier :: FileIdentifier -> FBState -> FBState
writeFileIdentifier fi = write fileIdentifierSize (B.byteString (unFileIdentifier fi))

{-# INLINE missing #-}
missing :: WriteTableField
missing = WriteTableField . pure $! id

{-# INLINE deprecated #-}
deprecated :: WriteTableField
deprecated = missing

{-# INLINE optional #-}
optional :: (a -> WriteTableField) -> (Maybe a -> WriteTableField)
optional = maybe missing

{-# INLINE optionalDef #-}
optionalDef :: Eq a => a -> (a -> WriteTableField) -> (Maybe a -> WriteTableField)
optionalDef dflt write ma =
  case ma of
    Just a | a /= dflt -> write a
    _                  -> missing


{-# INLINE writeWord8TableField #-}
writeWord8TableField :: Word8 -> WriteTableField
writeWord8TableField n = WriteTableField . pure $! write word8Size (B.word8 n) . alignTo word8Size 0

{-# INLINE writeWord16TableField #-}
writeWord16TableField :: Word16 -> WriteTableField
writeWord16TableField n = WriteTableField . pure $! write word16Size (B.word16LE n) . alignTo word16Size 0

{-# INLINE writeWord32TableField #-}
writeWord32TableField :: Word32 -> WriteTableField
writeWord32TableField n = WriteTableField . pure $! write word32Size (B.word32LE n) . alignTo word32Size 0

{-# INLINE writeWord64TableField #-}
writeWord64TableField :: Word64 -> WriteTableField
writeWord64TableField n = WriteTableField . pure $! write word64Size (B.word64LE n) . alignTo word64Size 0

{-# INLINE writeInt8TableField #-}
writeInt8TableField :: Int8 -> WriteTableField
writeInt8TableField n = WriteTableField . pure $! write int8Size (B.int8 n) . alignTo int8Size 0

{-# INLINE writeInt16TableField #-}
writeInt16TableField :: Int16 -> WriteTableField
writeInt16TableField n = WriteTableField . pure $! write int16Size (B.int16LE n) . alignTo int16Size 0

{-# INLINE writeInt32TableField #-}
writeInt32TableField :: Int32 -> WriteTableField
writeInt32TableField n = WriteTableField . pure $! write int32Size (B.int32LE n) . alignTo int32Size 0

{-# INLINE writeInt64TableField #-}
writeInt64TableField :: Int64 -> WriteTableField
writeInt64TableField n = WriteTableField . pure $! write int64Size (B.int64LE n) . alignTo int64Size 0

{-# INLINE writeFloatTableField #-}
writeFloatTableField :: Float -> WriteTableField
writeFloatTableField n = WriteTableField . pure $! write floatSize (B.floatLE n) . alignTo floatSize 0

{-# INLINE writeDoubleTableField #-}
writeDoubleTableField :: Double -> WriteTableField
writeDoubleTableField n = WriteTableField . pure $! write doubleSize (B.doubleLE n) . alignTo doubleSize 0

{-# INLINE writeBoolTableField #-}
writeBoolTableField :: Bool -> WriteTableField
writeBoolTableField = writeWord8TableField . boolToWord8

-- | The input is assumed not to exceed the buffer size limit of 2^31 - 1 bytes.
{-# INLINE writeTextTableField #-}
writeTextTableField :: Text -> WriteTableField
writeTextTableField text = WriteTableField $ do
  modify' (writeInt32 len . encodeText . alignTo int32Size (len + 1))
  uoffsetFromHere
  where
    len = utf8length text
    encodeText fbs =
      fbs
        -- strings must have a trailing zero
        { builder = T.encodeUtf8Builder text <> B.word8 0 <> builder fbs
        , bufferSize = Sum len <> Sum 1 <> bufferSize fbs
        }

{-# INLINE writeTableTableField #-}
writeTableTableField :: WriteTable a -> WriteTableField
writeTableTableField (WriteTable writeTable) = WriteTableField $ do
  loc <- writeTable
  pure $! uoffsetFrom loc

{-# INLINE writeStructTableField #-}
writeStructTableField :: forall a. IsStruct a => WriteStruct a -> WriteTableField
writeStructTableField (WriteStruct b) =
  writeStructTableField' (structAlignmentOf @a) (structSizeOf @a) b

{-# INLINE writeStructTableField' #-}
writeStructTableField' :: Alignment -> InlineSize -> Builder -> WriteTableField
writeStructTableField' structAlignment structSize structBuilder =
  WriteTableField . pure $! writeStruct . alignTo structAlignment 0
  where
    writeStruct fbs = fbs
      { builder = structBuilder <> builder fbs
      , bufferSize = bufferSize fbs <> Sum (fromIntegral @InlineSize @Int32 structSize)
      }

{-# INLINE writeUnionTypesVectorTableField #-}
writeUnionTypesVectorTableField :: WriteVector (WriteUnion a) -> WriteTableField
writeUnionTypesVectorTableField (WriteVectorUnion tf _) = tf

{-# INLINE writeUnionValuesVectorTableField #-}
writeUnionValuesVectorTableField :: WriteVector (WriteUnion a) -> WriteTableField
writeUnionValuesVectorTableField (WriteVectorUnion _ tf) = tf


{-# INLINE writeUnionTypeTableField #-}
writeUnionTypeTableField :: WriteUnion a -> WriteTableField
writeUnionTypeTableField !wu =
  case wu of
    None             -> missing
    Some unionType _ -> writeWord8TableField unionType


{-# INLINE writeUnionValueTableField #-}
writeUnionValueTableField :: WriteUnion a -> WriteTableField
writeUnionValueTableField !wu =
  case wu of
    None              -> missing
    Some _ unionValue -> writeTableTableField (WriteTable unionValue)

{-# INLINE none #-}
none :: WriteUnion a
none = None

{-# INLINE writeUnion #-}
writeUnion :: Word8 -> WriteTable a -> WriteUnion b
writeUnion n (WriteTable st) = Some n st

{-# INLINE vtable #-}
vtable :: [Word16] -> Word16 -> BSL.ByteString
vtable fieldVOffsets tableSize = bytestring
  where
    vtableSize = voffsetSize + voffsetSize + voffsetSize * fromIntegral @Int @Word16 (L.length fieldVOffsets)
    bytestring = B.toLazyByteString
      (  B.word16LE vtableSize
      <> B.word16LE (coerce tableSize)
      <> foldMap (B.word16LE . coerce) fieldVOffsets
      )


{-# INLINE writeTable #-}
writeTable :: [WriteTableField] -> WriteTable a
writeTable fields = WriteTable $ do

  inlineFields <- sequence (coerce fields)

  -- table
  tableEnd <- gets (getSum . bufferSize)

  inlineFieldPositions <-
    forM inlineFields $ \f -> do
      before <- gets bufferSize
      modify' f
      after <- gets bufferSize
      if after == before
        then pure 0
        else pure (getSum after)

  modify' $ alignTo soffsetSize 0
  tableFieldsPosition <- gets (getSum . bufferSize)

  let tablePosition = tableFieldsPosition + soffsetSize
  -- Note: This might overflow if the table has too many fields
  let tableSize = fromIntegral @Int32 @Word16 $ tablePosition - tableEnd
  let fieldVOffsets = flip fmap inlineFieldPositions $ \case
                  0 -> 0
                  -- Note: This might overflow if the table has too many fields
                  fieldPosition -> fromIntegral @Int32 @Word16 (tablePosition - fieldPosition)

  -- TODO: trim trailing 0 voffsets

  let newVtable = vtable fieldVOffsets tableSize
  let newVtableSize = fromIntegral @Int64 @Int32 (BSL.length newVtable)
  let newVtablePosition = tablePosition + newVtableSize

  map <- gets cache
  case M.insertLookupWithKey (\_k _new old -> old) newVtable newVtablePosition map of
    (Nothing, map') ->
      -- vtable, pointer to vtable, update the cache
      modify' (writeVtable map' newVtable newVtableSize . writeVtableSoffset newVtableSize)

    (Just oldVtablePosition, _) ->
      -- pointer to vtable
      modify' . writeInt32 . negate $ tablePosition - oldVtablePosition

  pure $! tablePosition

  where
    writeVtable newCache newVtable newVtableSize fbs = fbs
      { cache = newCache
      , builder = B.lazyByteString newVtable <> builder fbs
      , bufferSize = bufferSize fbs <> Sum newVtableSize
      }

    -- The vtable is located right before the table, so the offset
    -- between the table and the vtable is equal to the vtable size
    writeVtableSoffset newVtableSize = writeInt32 newVtableSize



class WriteVectorElement a where

  data WriteVector a

  -- |
  -- Implementer's note: We choose to ask for the collection's length to be passed in as an argument rather than use `Foldable.length` because:
  -- 1. `Foldable.length` is often O(1), and in some use cases there may be a better way to know the collection's length.
  -- 2. Calling `Foldable.length` inside `vector` can inhibit some fusions which would otherwise be possible.
  --
  -- For example, this version of `vector` that calls `Foldable.length` internally:
  --
  -- > encodeUserIds' :: [User] -> BSL.ByteString
  -- > encodeUserIds' = encode . userIdsTable $ vector (userId <$> users))
  -- >
  -- > {-# INLINE vector #-}
  -- > vector xs =
  -- >   let length = Foldable.length xs
  -- >       buffer = foldr ... ... xs
  -- >   in  ...
  --
  -- ...prevents `<$>` and `foldr` from being fused, and so it's 4x slower than when the length is passed in:
  --
  -- > encodeUserIds :: [User] -> BSL.ByteString
  -- > encodeUserIds = encode . userIdsTable $ vector (userId <$> users) (fromIntegral (F.length users))
  -- >
  -- > {-# INLINE vector #-}
  -- > vector xs length =
  -- >   let buffer = foldr ... ... xs
  -- >   in  ...
  vector :: Foldable f => Int32 -> f a -> WriteVector a

-- | Convenience function, equivalent to
-- > vector' xs = vector (fromIntegral $ Foldable.length xs) xs
-- In some cases it may be slower than using `vector` directly.
{-# INLINE vector' #-}
vector' :: WriteVectorElement a => Foldable f => f a -> WriteVector a
vector' xs = vector (fromIntegral $ Foldable.length xs) xs

{-# INLINE inlineVector #-}
inlineVector :: Foldable f => (a -> Builder) -> Alignment -> InlineSize -> Int32 -> f a -> WriteTableField
inlineVector build elemAlignment elemSize elemCount elems = WriteTableField $ do
  modify' $!
    writeInt32 elemCount . writeVec . alignTo (coerce elemAlignment `max` int32Size) vecByteLength

  uoffsetFromHere
  where
    vecByteLength = elemCount * fromIntegral @InlineSize @Int32 elemSize
    vecBuilder = foldr (\a b -> build a <> b) mempty elems
    writeVec fbs =
      fbs
        { builder = vecBuilder <> builder fbs
        , bufferSize = bufferSize fbs <> Sum vecByteLength
        }

instance WriteVectorElement Word8 where
  newtype WriteVector Word8 = WriteVectorWord8 { writeVectorWord8TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Word8 -> WriteVector Word8
  vector n = WriteVectorWord8 . inlineVector B.word8 word8Size word8Size n

instance WriteVectorElement Word16 where
  newtype WriteVector Word16 = WriteVectorWord16 { writeVectorWord16TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Word16 -> WriteVector Word16
  vector n = WriteVectorWord16 . inlineVector B.word16LE word16Size word16Size n

instance WriteVectorElement Word32 where
  newtype WriteVector Word32 = WriteVectorWord32 { writeVectorWord32TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Word32 -> WriteVector Word32
  vector n = WriteVectorWord32 . inlineVector B.word32LE word32Size word32Size n

instance WriteVectorElement Word64 where
  newtype WriteVector Word64 = WriteVectorWord64 { writeVectorWord64TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Word64 -> WriteVector Word64
  vector n = WriteVectorWord64 . inlineVector B.word64LE word64Size word64Size n

instance WriteVectorElement Int8 where
  newtype WriteVector Int8 = WriteVectorInt8 { writeVectorInt8TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Int8 -> WriteVector Int8
  vector n = WriteVectorInt8 . inlineVector B.int8 int8Size int8Size n

instance WriteVectorElement Int16 where
  newtype WriteVector Int16 = WriteVectorInt16 { writeVectorInt16TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Int16 -> WriteVector Int16
  vector n = WriteVectorInt16 . inlineVector B.int16LE int16Size int16Size n

instance WriteVectorElement Int32 where
  newtype WriteVector Int32 = WriteVectorInt32 { writeVectorInt32TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Int32 -> WriteVector Int32
  vector n = WriteVectorInt32 . inlineVector B.int32LE int32Size int32Size n

instance WriteVectorElement Int64 where
  newtype WriteVector Int64 = WriteVectorInt64 { writeVectorInt64TableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Int64 -> WriteVector Int64
  vector n = WriteVectorInt64 . inlineVector B.int64LE int64Size int64Size n

instance WriteVectorElement Float where
  newtype WriteVector Float = WriteVectorFloat { writeVectorFloatTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Float -> WriteVector Float
  vector n = WriteVectorFloat . inlineVector B.floatLE floatSize floatSize n

instance WriteVectorElement Double where
  newtype WriteVector Double = WriteVectorDouble { writeVectorDoubleTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Double -> WriteVector Double
  vector n = WriteVectorDouble . inlineVector B.doubleLE doubleSize doubleSize n

instance WriteVectorElement Bool where
  newtype WriteVector Bool = WriteVectorBool { writeVectorBoolTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Bool -> WriteVector Bool
  vector n = WriteVectorBool . inlineVector (B.word8 . boolToWord8) word8Size word8Size n

instance IsStruct a => WriteVectorElement (WriteStruct a) where
  newtype WriteVector (WriteStruct a) = WriteVectorStruct { writeVectorStructTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f (WriteStruct a) -> WriteVector (WriteStruct a)
  vector n = WriteVectorStruct . inlineVector coerce (structAlignmentOf @a) (structSizeOf @a) n


data TextInfos = TextInfos ![TextInfo] {-# UNPACK #-} !BufferSize

data TextInfo = TextInfo
  { tiText     :: !Text
  , tiUtf8len  :: {-# UNPACK #-} !Int32
  , tiPadding  :: {-# UNPACK #-} !Int32
  , tiPosition :: {-# UNPACK #-} !Position
  }

data OffsetInfo = OffsetInfo
  { oiIndex   :: {-# UNPACK #-} !Int32
  , oiOffsets :: ![Int32]
  }

instance WriteVectorElement Text where
  newtype WriteVector Text = WriteVectorText { writeVectorTextTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f Text -> WriteVector Text
  vector elemCount texts = WriteVectorText . WriteTableField $ do
    modify' $ \fbs ->
      let (builder2, bsize2) =
            writeVectorSizePrefix . writeOffsets . align . writeStrings $ (builder fbs, bufferSize fbs)
      in  fbs
            { builder = builder2
            , bufferSize = bsize2
            , maxAlign = maxAlign fbs <> Max int32Size
            }
    uoffsetFromHere
    where
      writeStrings :: (Builder, BufferSize) -> (Builder, BufferSize, [TextInfo])
      writeStrings (builder1, bsize1) =
          -- Collect info about the strings.
          -- NOTE: this loop *could* be merged with the one below, but
          -- we have loops dedicated to merging Builders to avoid wrapping Builders in data structures.
          -- See "Performance tips": http://hackage.haskell.org/package/fast-builder-0.1.0.1/docs/Data-ByteString-FastBuilder.html
        let TextInfos textInfos bsize2 =
              foldr
                (\t (TextInfos infos bsize) ->
                  let textLength = utf8length t
                      padding = calcPadding 4 (textLength + 1) bsize
                      newBsize = bsize <> Sum (padding + textLength + 1 + 4)
                  in  TextInfos (TextInfo t textLength padding (getSum newBsize) : infos) newBsize
                )
                (TextInfos [] bsize1)
                texts

            builder2 =
              foldr
                (\(TextInfo t tlength padding _) b ->
                  B.int32LE tlength
                  <> T.encodeUtf8Builder t
                  <> B.word8 0 -- strings must have a trailing zero
                  <> buildPadding padding
                  <> b
                )
                mempty
                textInfos
        in (builder2 <> builder1, bsize2, textInfos)

      align :: (Builder, BufferSize, [TextInfo]) -> (Builder, BufferSize, [TextInfo])
      align (builder1, bsize1, textInfos) =
        let vectorPadding = calcPadding int32Size 0 bsize1
            bsize2 = bsize1 <> Sum vectorPadding
            builder2 = buildPadding vectorPadding
        in  (builder2 <> builder1, bsize2, textInfos)

      writeOffsets :: (Builder, BufferSize, [TextInfo]) -> (Builder, BufferSize)
      writeOffsets (builder1, bsize1, textInfos) =
        let OffsetInfo _ offsets =
              foldr
                (\(TextInfo _ _ _ position) (OffsetInfo ix os) ->
                  OffsetInfo
                    (ix + 1)
                    (getSum bsize1 + (ix * 4) + 4 - position : os)
                )
                (OffsetInfo 0 [])
                textInfos

            bsize2 = bsize1 <> Sum (elemCount * 4)
            builder2 =
              foldr
                (\o b -> B.int32LE o <> b)
                mempty
                offsets
        in  (builder2 <> builder1, bsize2)

      writeVectorSizePrefix :: (Builder, BufferSize) -> (Builder, BufferSize)
      writeVectorSizePrefix (builder1, bsize1) =
        (B.int32LE elemCount <> builder1, bsize1 + int32Size)



data TableInfo = TableInfo
  { tiState          :: !FBState
  , tiTablePositions :: ![Position]
  }

instance WriteVectorElement (WriteTable a) where
  newtype WriteVector (WriteTable a) = WriteVectorTable { writeVectorTableTableField :: WriteTableField }

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f (WriteTable a) -> WriteVector (WriteTable a)
  vector elemCount tables = WriteVectorTable . WriteTableField $ do
    fbs1 <- get
    let !(TableInfo fbs2 positions) =
          foldr
            (\(WriteTable writeTable) (TableInfo fbs positions) ->
              let (pos, fbs') = runState writeTable fbs
              in  TableInfo fbs' (pos : positions)
            )
            (TableInfo fbs1 [])
            tables
    put $! alignTo int32Size 0 fbs2

    -- Write offsets
    bsize <- gets (getSum . bufferSize)
    let OffsetInfo _ offsets =
          foldr
            (\position (OffsetInfo ix os) ->
              OffsetInfo
                (ix + 1)
                (bsize + (ix * 4) + 4 - position : os)
            )
            (OffsetInfo 0 [])
            positions

    coerce $ vector elemCount offsets

data Vecs a = Vecs ![Word8] ![Maybe (State FBState Position)]

data UnionTableInfo = UnionTableInfo
  { utiState          :: !FBState
  , utiTablePositions :: ![Maybe Position]
  }

instance WriteVectorElement (WriteUnion a) where
  data WriteVector (WriteUnion a) = WriteVectorUnion !WriteTableField !WriteTableField

  {-# INLINE vector #-}
  vector :: Foldable f => Int32 -> f (WriteUnion a) -> WriteVector (WriteUnion a)
  vector elemCount unions =
    let Vecs types values =
          foldr
            go
            (Vecs [] [])
            unions
        go writeUnion (Vecs types values) =
          case writeUnion of
            None         -> Vecs (0 : types) (Nothing : values)
            Some typ val -> Vecs (typ : types) (Just val : values)

        writeUnionTables :: WriteTableField
        writeUnionTables = WriteTableField $ do
              fbs1 <- get
              let !(UnionTableInfo fbs2 positions) =
                    foldr
                      (\unionTableOpt (UnionTableInfo fbs positions) ->
                        case unionTableOpt of
                          Just t ->
                            let (pos, fbs') = runState t fbs
                            in  UnionTableInfo fbs' (Just pos : positions)
                          Nothing ->
                            UnionTableInfo fbs (Nothing : positions)
                      )
                      (UnionTableInfo fbs1 [])
                      values
              put $! alignTo int32Size 0 fbs2


              -- Write offsets
              bsize <- gets (getSum . bufferSize)
              let OffsetInfo _ offsets =
                    foldr
                      (\positionOpt (OffsetInfo ix os) ->
                        let offset =
                              case positionOpt of
                                Just position -> bsize + (ix * 4) + 4 - position
                                Nothing       -> 0
                        in  OffsetInfo
                              (ix + 1)
                              (offset : os)
                      )
                      (OffsetInfo 0 [])
                      positions

              coerce $ vector elemCount offsets

    in  WriteVectorUnion (coerce $ vector elemCount types) writeUnionTables



-- | Calculate how much 0-padding is needed so that, after writing @additionalBytes@,
-- the buffer becomes aligned to @n@ bytes.
{-# INLINE calcPadding #-}
calcPadding :: Alignment {- ^ n -} -> Int32 {- ^ additionalBytes -} -> BufferSize -> Int32
calcPadding !n !additionalBytes (Sum size) =
  -- TODO: optimize this: https://hackage.haskell.org/package/base-4.12.0.0/docs/Data-Bits.html
  if n == 0
    then 0
    else
      let remainder = (size + additionalBytes) `rem` fromIntegral @Alignment @Int32 n
          needed = if remainder == 0 then 0 else fromIntegral @Alignment @Int32 n - remainder
      in  needed

-- | Add enough 0-padding so that the buffer becomes aligned to @n@ after writing @additionalBytes@.
{-# INLINE alignTo #-}
alignTo :: Alignment{- ^ n -} -> Int32 {- ^ additionalBytes -} -> FBState -> FBState
alignTo !n !additionalBytes fbs@(FBState b bsize ma cache) =
  if padding == 0
    then fbs { maxAlign = ma <> coerce n }
    else FBState
            (buildPadding padding <> b)
            (bsize <> Sum padding)
            (ma <> coerce n)
            cache
  where
    padding = calcPadding n additionalBytes bsize


{-# INLINE uoffsetFromHere #-}
uoffsetFromHere :: State FBState (FBState -> FBState)
uoffsetFromHere = gets (uoffsetFrom . coerce . bufferSize)

{-# INLINE uoffsetFrom #-}
uoffsetFrom :: Position -> FBState -> FBState
uoffsetFrom pos = writeUOffset . align
  where
    align fbs = alignTo int32Size 0 fbs
    writeUOffset fbs =
      let currentPos = coerce bufferSize fbs
      in  writeInt32 (currentPos - pos + uoffsetSize) fbs

{-# INLINE utf8length #-}
utf8length :: Text -> Int32
utf8length (TI.Text arr off len)
  | len == 0  = 0
  | otherwise = unsafeDupablePerformIO $
    c_length_utf8 (A.aBA arr) (fromIntegral off) (fromIntegral len)

foreign import ccall unsafe "_hs_text_length_utf8" c_length_utf8
  :: ByteArray# -> CSize -> CSize -> IO Int32
