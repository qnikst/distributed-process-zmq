{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- Module provides missing functionality for the other packages.
--
-- All contents of this module will eventually pushed to the other
-- packages.
--
-- Contents:
--
--   * Typeable instances for zeromq4-haskell
--
module Control.Distributed.Process.Backend.ZMQ.Missing
  (
  ) where

import           Data.Typeable
import qualified System.ZMQ4 as ZMQ

deriving instance Typeable ZMQ.Push
deriving instance Typeable ZMQ.Req
deriving instance Typeable ZMQ.Sub
