{-# LANGUAGE OverloadedStrings #-}

module Bench where

import           Criterion.Main

import           FlatBuffers.Read
import           FlatBuffers.Write

import           Types

groups :: [Benchmark]
groups =
  [ bgroup "Write" $
    [ bench "mkj" $ nf encode $
        scalars
            (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
            (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
            (Just 1234.56) (Just 2873242.82782) (Just True) $ Just $
          scalars
              (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
              (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
              (Just 1234.56) (Just 2873242.82782) (Just True) $ Just $
            scalars
              (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
              (Just maxBound) (Just maxBound) (Just maxBound) (Just maxBound)
              (Just 1234.56) (Just 2873242.82782) (Just True) Nothing
    ]
  ]
