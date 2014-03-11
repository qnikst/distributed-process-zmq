{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- | Module provides an extended version of channels.
--
-- Technitial depts:
--
--    [ ] ability to use generated address
--
--    [ ] exception handling mechanism
--
--    [ ] return errors
--
--    [ ] use different types in chan
--
module Control.Distributed.Process.Backend.ZMQ.Channel
  ( 
    -- * Basic API
    -- ** Channel pairs
    -- $channel-pairs
    ChannelPair
  , pair
  , singleIn
  , singleOut
  , PairOptions(..)
  , ReceiveOptions(..)
  , registerSend
  , registerReceive
    -- ** Extended functions
    -- $extended-functions
  , SendPortEx(..)
  , receiveChanEx
  ) where

import qualified Control.Concurrent.Async as Async
import           Control.Concurrent.STM
import           Control.Concurrent.MVar
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Distributed.Process.Internal.Types
import           Control.Monad
      ( forever 
      , void
      )
import           Data.Binary
import           Data.ByteString
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as B8
import qualified Data.Foldable as Foldable
import           Data.List.NonEmpty
      ( NonEmpty(..)
      )
import           Data.Typeable

import           GHC.Generics
import qualified System.ZMQ4 as ZMQ
import           Network.Transport
import           Network.Transport.ZMQ.Types

import           Control.Distributed.Process.ChannelEx
import           Control.Distributed.Process.Backend.ZMQ.Missing

-- $channel-pairs
-- Channel pairs provides type safe way to create a pair of sockets 
-- the instances and handle all internal information that is required
-- to handle such channels.

instance ChannelPair ZMQ.Pub  ZMQ.Sub
instance ChannelPair ZMQ.Push ZMQ.Pull
instance ChannelPair ZMQ.Req  ZMQ.Rep
instance ChannelPair ZMQ.Dealer ZMQ.Rep
instance ChannelPair ZMQ.Dealer ZMQ.Router
instance ChannelPair ZMQ.Dealer ZMQ.Dealer
instance ChannelPair ZMQ.Router ZMQ.Router
instance ChannelPair ZMQ.Pair   ZMQ.Pair

type SocketAddress = ByteString

data ChanAddrIn  t a = ChanAddrIn  SocketAddress deriving (Generic, Typeable)
data ChanAddrOut t a = ChanAddrOut SocketAddress deriving (Generic, Typeable)

mkProxyChIn :: ChanAddrIn x a -> Proxy1 a
mkProxyChIn _ = Proxy1

mkProxyChOut :: ChanAddrOut x a -> Proxy1 a
mkProxyChOut _ = Proxy1

data ZMQSocket a = ZMQSocket 
      { socketState :: MVar (ZMQSocketState a)
      }

data ZMQSocketState a = ZMQSocketValid  (ValidZMQSocket a)
                      | ZMQSocketClosed

data ValidZMQSocket a = ValidZMQSocket a

-- list of serializable sockets
instance Binary (ChanAddrIn t a) where
instance Binary (ChanAddrOut t a) where
instance Typeable a => Serializable (ChanAddrIn  ZMQ.Push a) where
instance Typeable a => Serializable (ChanAddrIn  ZMQ.Req  a) where
instance Typeable a => Serializable (ChanAddrOut ZMQ.Sub  a) where

data PairOptions  = PairOptions
      { poAddress :: Maybe ByteString -- ^ Override transport socket address.
      }

-- | Create socket pair. This function returns a \'tickets\' that can be
-- converted into a real sockets with 'registerSend' or 'registerReceive'.
-- User will have to covert local \'ticket\' into socket immediatelly,
-- so remote side can connect to it.
pair :: ChannelPair t1 t2
     => (t1, t2)      -- ^ Socket types,
     -> PairOptions   -- ^ Configuration options.
     -> Process (ChanAddrIn t1 a, ChanAddrOut t2 a)
pair _ o = case poAddress o of
   Just addr -> return (ChanAddrIn addr, ChanAddrOut addr)
   Nothing   -> error "Not yet implemented." 

-- | Create output channel, when remote side is outside distributed-process
-- cluster. Serializable restriction says that the return type of socket is
-- a \'client\' for remote server.
singleOut :: (ChannelPair t1 t2, Serializable (ChanAddrIn t1 a))
          => t1
          -> t2
          -> SocketAddress
          -> ChanAddrOut t2 a
singleOut _ _ addr = ChanAddrOut addr

-- | Create input channel, when remote side is outside distributed-process
-- cluster
singleIn :: (ChannelPair t1 t2, Serializable (ChanAddrOut t2 a))
         => t1
         -> t2
         -> SocketAddress
         -> ChanAddrIn t2 a
singleIn _ _ addr = ChanAddrIn addr

---------------------------------------------------------------------------------
-- Receive socket instances
---------------------------------------------------------------------------------

instance ChannelReceive (ChanAddrOut ZMQ.Sub) where
  type ReceiveTransport (ChanAddrOut ZMQ.Sub)   = ZMQTransport
  type ReceiveResult    (ChanAddrOut ZMQ.Sub) a = a
  data ReceiveOptions   (ChanAddrOut ZMQ.Sub)   = SubReceive (NonEmpty ByteString)
  registerReceive t (SubReceive sbs) ch@(ChanAddrOut addr) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
          q <- newTQueueIO
          s <- ZMQ.socket (_transportContext v) ZMQ.Sub
          ZMQ.connect s (B8.unpack addr)
          Foldable.mapM_ (ZMQ.subscribe s) sbs
          tid <- Async.async $ forever $ do
              lst <- ZMQ.receiveMulti s
              atomically $ writeTQueue q (decodeList' (mkProxyChOut ch) lst)
          return . Just $ ReceivePortEx 
            { receiveEx = ReceivePort $ readTQueue q
            , closeReceiveEx = liftIO $ do
                Async.cancel tid
                ZMQ.disconnect s (B8.unpack addr)
                ZMQ.close s
            }
      TransportClosed -> return Nothing

instance ChannelReceive (ChanAddrOut ZMQ.Pull) where
  type ReceiveTransport (ChanAddrOut ZMQ.Pull)   = ZMQTransport
  type ReceiveResult    (ChanAddrOut ZMQ.Pull) a = a
  data ReceiveOptions   (ChanAddrOut ZMQ.Pull)   = PullReceive 
  registerReceive t PullReceive ch@(ChanAddrOut addr) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
        q <- newTQueueIO
        s <- ZMQ.socket (_transportContext v) ZMQ.Pull
        ZMQ.connect s (B8.unpack addr)
        tid <- Async.async $ forever $ do
            lst <- ZMQ.receiveMulti s
            atomically $ writeTQueue q (decodeList' (mkProxyChOut ch) lst)
        return . Just $ ReceivePortEx
            { receiveEx = ReceivePort $ readTQueue q
            , closeReceiveEx = liftIO $ do
                Async.cancel tid
                ZMQ.disconnect s (B8.unpack addr)
                ZMQ.close s
            }
      TransportClosed -> return Nothing

instance ChannelReceive (ChanAddrOut ZMQ.Rep) where
  type ReceiveTransport (ChanAddrOut ZMQ.Rep)   = ZMQTransport
  type ReceiveResult    (ChanAddrOut ZMQ.Rep) a = (a -> IO a) -> IO ()
  data ReceiveOptions   (ChanAddrOut ZMQ.Rep)   = ReqReceive
  registerReceive t ReqReceive ch@(ChanAddrOut addr) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
        req <- newEmptyTMVarIO
        rep <- newEmptyTMVarIO
        s <- ZMQ.socket (_transportContext v) ZMQ.Rep
        ZMQ.bind s (B8.unpack addr)
        tid <- Async.async $ forever $ do
            lst <- ZMQ.receiveMulti s
            atomically $ putTMVar req $ \f -> do 
              y <- f $ decodeList' (mkProxyChOut ch) lst
              liftIO $ atomically $ putTMVar rep $ encodeList' y
            ZMQ.sendMulti s =<< (atomically $ takeTMVar rep)
        return . Just $ ReceivePortEx
            { receiveEx = ReceivePort $ takeTMVar req
            , closeReceiveEx = liftIO $ do
                Async.cancel tid
                ZMQ.disconnect s (B8.unpack addr)
                ZMQ.close s
            }
      TransportClosed -> return Nothing

---------------------------------------------------------------------------------
-- Send socket instances
---------------------------------------------------------------------------------

instance ChannelSend (ChanAddrIn ZMQ.Pub) where
    type SendTransport (ChanAddrIn ZMQ.Pub)   = ZMQTransport
    type SendValue     (ChanAddrIn ZMQ.Pub) a = a
    registerSend t (ChanAddrIn addr) = liftIO $ 
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Pub
          ZMQ.bind s (B8.unpack addr)
          st <- newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx
            { sendEx = liftIO . (sendInner t (ZMQSocket st))
            , closeSendEx = liftIO $ do
                void $ swapMVar st ZMQSocketClosed
                ZMQ.unbind s (B8.unpack addr)
                ZMQ.close  s
            }
        TransportClosed -> return Nothing 

instance ChannelSend (ChanAddrIn ZMQ.Push) where
    type SendTransport (ChanAddrIn ZMQ.Push)   = ZMQTransport
    type SendValue     (ChanAddrIn ZMQ.Push) a = a
    registerSend t (ChanAddrIn addr) = liftIO $
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Push
          ZMQ.bind s (B8.unpack addr)
          st <- newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx 
            { sendEx = liftIO . (sendInner t (ZMQSocket st))
            , closeSendEx = liftIO $ do 
                void $ swapMVar st ZMQSocketClosed
                ZMQ.unbind s (B8.unpack addr)
                ZMQ.close  s
            }
        TransportClosed -> return Nothing 

instance ChannelSend (ChanAddrIn ZMQ.Req) where
    type SendTransport (ChanAddrIn ZMQ.Req)   = ZMQTransport
    type SendValue     (ChanAddrIn ZMQ.Req) a = (a, a -> IO ())
    registerSend t ch@(ChanAddrIn addr) = liftIO $ 
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Req
          ZMQ.connect s (B8.unpack addr)
          st <- newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx 
            { sendEx = \(a, fa) -> liftIO $ do
                ex <- sendInner t (ZMQSocket st) a
                case ex of 
                  Right _ -> do
                    xbs <- ZMQ.receiveMulti s
                    fa $ decodeList' (mkProxyChIn ch) xbs
                    return $ Right ()
                  Left e -> return $ Left e
            , closeSendEx = liftIO $ do
                void $ swapMVar st ZMQSocketClosed
                ZMQ.disconnect s (B8.unpack addr)
                ZMQ.close  s
            }
        TransportClosed -> return Nothing 

sendInner :: (ZMQ.Sender s, Serializable a) => ZMQTransport -> ZMQSocket (ZMQ.Socket s) -> a -> IO (Either (TransportError SendErrorCode) ())
sendInner transport socket msg = withMVar (socketState socket) $ \case
  ZMQSocketValid (ValidZMQSocket s) -> withMVar (_transportState transport) $ \case
    TransportValid{} -> ZMQ.sendMulti s (encodeList' msg) >> return (Right ())
    TransportClosed  -> return $ Left $ TransportError SendFailed "Transport is closed."
  ZMQSocketClosed  -> return $ Left $ TransportError SendClosed "Socket is closed."

decodeList' :: Binary a => Proxy1 a -> [ByteString] -> a
decodeList' _ = decode . BL.fromChunks

encodeList' :: Binary a => a -> NonEmpty ByteString
encodeList' x = case BL.toChunks (encode x) of
   [] -> error "encodeList'"
   (b:bs) -> b :| bs

