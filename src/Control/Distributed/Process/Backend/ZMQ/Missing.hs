{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | 
-- Module:    Control.Distributed.Process.Backend.ZMQ.Missing
-- Copyright: 2014 (C) EURL Tweag
-- License:   BSD-3
-- 
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
  , sendInner
  , registerSocket
  , closeSocket
  ) where

import           Data.Typeable
import           Data.Unique
import           Control.Monad ( void, join )
import           Control.Concurrent.MVar
import qualified System.ZMQ4 as ZMQ
import           Data.List.NonEmpty
import           Data.ByteString (ByteString)
import           Network.Transport
import           Network.Transport.ZMQ
import           Network.Transport.ZMQ.Internal.Types

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
                      | ZMQSocketPending

data ValidZMQSocket a = ValidZMQSocket (ZMQ.Socket a) Unique

registerSocket :: ZMQ.SocketType a => ValidTransportState -> ZMQ.Socket a -> IO (ZMQSocket a)
registerSocket zmq sock = do
    mvr <- newMVar ZMQSocketPending
    Just u <- registerValidCleanupAction zmq $ modifyMVar_ mvr $ \case
        ZMQSocketValid ValidZMQSocket{} -> do
          ZMQ.close sock
          return ZMQSocketClosed
        _ -> return ZMQSocketClosed
    void $ swapMVar mvr (ZMQSocketValid (ValidZMQSocket sock u))
    return $ ZMQSocket mvr

closeSocket :: ZMQ.SocketType a => ZMQTransport -> ZMQSocket a -> IO ()
closeSocket zmq (ZMQSocket s) = join $ modifyMVar s $ \case
  ZMQSocketValid (ValidZMQSocket _ u) -> return (ZMQSocketClosed, applyCleanupAction zmq u)
  _ -> return (ZMQSocketClosed, return ())


sendInner :: ZMQ.Sender s => ZMQTransport -> ZMQSocket s -> NonEmpty ByteString -> IO (Either (TransportError SendErrorCode) ())
sendInner transport socket msg = withMVar (socketState socket) $ \case
  ZMQSocketValid (ValidZMQSocket s _) -> withMVar (_transportState transport) $ \case
    TransportValid{} -> ZMQ.sendMulti s msg >> return (Right ())
    TransportClosed  -> return $ Left $ TransportError SendFailed "Transport is closed."
  _ -> return $ Left $ TransportError SendClosed "Socket is closed."
