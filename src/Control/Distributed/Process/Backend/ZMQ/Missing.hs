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
--   * Types for raw socket for network-transport-zeromq
--
module Control.Distributed.Process.Backend.ZMQ.Missing
  ( Proxy1(..)
  -- * network-transport-zeromq
  , ZMQSocket(..)
  , ZMQSocketState(..)
  , ValidZMQSocket(..)
  ) where

import           Data.Typeable
import           Control.Concurrent.MVar (MVar)
import qualified System.ZMQ4 as ZMQ

-- zeromq4-haskell
deriving instance Typeable ZMQ.Push
deriving instance Typeable ZMQ.Req
deriving instance Typeable ZMQ.Sub

data Proxy1 a = Proxy1

-- network-transport-zeromq

-- | Wrapper for socket
data ZMQSocket a = ZMQSocket 
      { socketState :: MVar (ZMQSocketState a)
      }

data ZMQSocketState a = ZMQSocketValid  (ValidZMQSocket a)
                      | ZMQSocketClosed

data ValidZMQSocket a = ValidZMQSocket a
