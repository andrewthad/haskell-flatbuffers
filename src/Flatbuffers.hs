{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Flatbuffers where

import Control.Monad.State
import Data.Bifunctor
import Data.Int
import Data.Word
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.List as L
import Debug.Trace
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Builder as B
import Data.ByteString.Builder (Builder, toLazyByteString)

go =
  putStrLn "Dumping" >>
  BSL.writeFile "bs.txt" (toLazyByteString $ root st)

st =
  table [
    scalar struct [
      padded 4 $ int32 1,
      int64 2,
      padded 4 $ float 3
    ]
  ]

vectors =
  table [
    vector [text "hi", string "bye"],
    vector [scalar int32 12, scalar int32 34],
    vector [scalar int64 23, scalar int64 45]
  ]

variety =
  table [
    scalar word8 8,
    scalar word8 2,
    table [
      scalar int32 670
    ],
    scalar bool True
  ]

obj = table [
    scalar int32 123,
    text "hello",
    scalar int64 999,
    text "bye",
    scalar int32 456
  ]

nested = 
  table [
    scalar int32 12399,
    table [
      scalar int32 99456,
      text "byehello"
    ]
  ]

type BytesWritten = Int
type Offset = BytesWritten
type InlineSize = Word16
type BState = (Builder, BytesWritten)

newtype Field = Field { dump :: State BState InlineField }

newtype InlineField = InlineField { write :: State BState InlineSize }

referenceSize :: Num a => a
referenceSize = 4

scalar' :: InlineField -> Field
scalar' = Field . pure

scalar :: (a -> InlineField) -> (a -> Field)
scalar f = scalar' . f

primitive :: InlineSize -> (a -> Builder) -> a -> InlineField
primitive size f a =
  InlineField $ do
    (b, bw) <- get
    put (f a <> b, bw + fromIntegral size)
    pure size


int32 :: Int32 -> InlineField
int32 = primitive 4 B.int32LE

int64 :: Int64 -> InlineField
int64 = primitive 8 B.int64LE

word8 :: Word8 -> InlineField
word8 = primitive 1 B.word8

float :: Float -> InlineField
float = primitive 4 B.floatLE

double :: Double -> InlineField
double = primitive 4 B.doubleLE

bool :: Bool -> InlineField
bool = primitive 1 $ \case
  True  -> B.word8 1
  False -> B.word8 0


-- | A missing field.
-- | Use this when serializing a deprecated field, or to tell clients to use the default value.
missing :: Field
missing = Field . pure . InlineField $ pure 0

text :: Text -> Field
text t = Field $ do
  (b, bw) <- get
  let (b2, bw2) = (B.int32LE (fromIntegral (T.length t)) <> T.encodeUtf8Builder t <> b, bw + referenceSize + T.length t)
  put (b2, bw2)
  pure $ offsetFrom bw2

string :: String -> Field
string s = Field $ do
  (b, bw) <- get
  let (b2, bw2) = (B.int32LE (L.genericLength s) <> B.stringUtf8 s <> b, bw + referenceSize + length s)
  put (b2, bw2)
  pure $ offsetFrom bw2

root :: Field -> Builder
root field =
  fst $ execState
    (dump field >>= write)
    (mempty, 0)


struct :: [InlineField] -> InlineField
struct fields = InlineField $
  sum <$> traverse write (reverse fields)


padded :: Word16 -> InlineField -> InlineField
padded n field = InlineField $ do
  sequence_ $ L.genericReplicate n (write $ word8 0)
  size <- write field
  pure (size + n)

table :: [Field] -> Field
table fields = Field $ do
  inlineFields <- traverse dump (reverse fields)
  inlineSizes <- traverse write inlineFields

  let fieldOffsets = calcFieldOffsets referenceSize (reverse inlineSizes)
  let vtableSize = 2 + 2 + 2 * L.genericLength fields
  let tableSize = referenceSize + fromIntegral (sum inlineSizes)

  (b, bw)  <- get

  -- table
  let (b2, bw2) = (B.int32LE vtableSize <> b, bw + 4)

  -- vtable
  let (b3, bw3) = (B.word16LE vtableSize <> B.word16LE tableSize <> foldMap B.word16LE fieldOffsets <> b2, bw2 + vtableSize)
  
  put (b3, bw3)
  pure $ offsetFrom bw2

vector :: [Field] -> Field
vector fields = Field $ do
  inlineFields <- traverse dump (reverse fields)
  inlineSizes <- traverse write inlineFields
  write (int32 (L.genericLength fields))
  (_, bw) <- get
  pure $ offsetFrom bw

offsetFrom :: BytesWritten -> InlineField
offsetFrom bw = InlineField $ do
  (_, bw2) <- get
  write (int32 (fromIntegral (bw2 - bw) + referenceSize))

calcFieldOffsets :: Word16 -> [InlineSize] -> [Word16]
calcFieldOffsets seed [] = []
calcFieldOffsets seed (0 : xs) = 0 : calcFieldOffsets seed xs
calcFieldOffsets seed (x : xs) = seed : calcFieldOffsets (seed + x) xs


