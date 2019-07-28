{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE FlexibleContexts #-}

module Examples.Generated where

import           FlatBuffers.Internal.Compiler.TH
import           FlatBuffers.Internal.Write

$(mkFlatBuffers "test/Examples/schema.fbs"           defaultOptions)
$(mkFlatBuffers "test/Examples/vector_of_unions.fbs" defaultOptions)
