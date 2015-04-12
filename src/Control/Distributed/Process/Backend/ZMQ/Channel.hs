{-# LANGUAGE OverloadedStrings #-}
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
-- | Module:    Control.Distributed.Process.ZMQ.Channel
-- Copyright: 2014 (C) EURL Tweag
-- License:   BSD-3
-- 
-- This module provides a channels for different socket types that are
-- provided by zeromq. For additional information about extended channels
-- refer to "Control.Distributed.Process.ChannelEx".
--
module Control.Distributed.Process.Backend.ZMQ.Channel
  ( 
    -- * Basic API
    -- ** Channel pairs
    -- $channel-pairs
    pair
  , PairOptions(..)
  , singleIn
  , singleOut
  , ChanAddrIn
  , ChanAddrOut
  , ReceiveOptions(..)
  , SocketAddress
  ) where

import           Control.Monad
      ( forever )
import qualified Control.Concurrent.Async as Async
import           Control.Concurrent.STM
import           Control.Concurrent.MVar
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Distributed.Process.Internal.Types
import           Data.Accessor ((^.))
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
import           Network.Transport.ZMQ.Internal.Types

import           Control.Distributed.Process.ChannelEx
import           Control.Distributed.Process.Backend.ZMQ.Missing

-- $channel-pairs
-- Channel pairs provides type safe way to create a pair of sockets 
-- the instances and handle all internal information that is required
-- to handle such channels. Possible patterns:
--
--   * 'ZMQ.Pub' -> 'ZMQ.Sub' (Publish Subscribe pattern)
--   
-- >    Server: ZMQ.Pub
-- >    SendType: (ByteString, a) 
-- >      ByteString is a prefix (channel), clients can filter only messages they are interested in.
-- >    ReceiveType: a
-- >    ReceiveOptions: SubReceive Bytestring
-- >      Set filter for interesting messages where filter string should be a prefix
--
--     Publish subscribe pattern has a limitation, as it's mandratory to
--     have a channel, that will be a first chunk in ZeroMQ messages, so
--     it's not possible to communicate with external nodes that have
--     a different aproach.
--
--   * 'ZMQ.Push' -> 'ZMQ.Pull' (Load balancing pattern)
--
-- >   Server: ZMQ.Push
-- >   SendType: a
-- >   ReceiveType: a
-- >   ReceiveOptions: PullReceive
--
--     Load balancing pattern, any message that were send to push socket
--     will be received by only one client, in a round robin fasion.
--
--  * 'ZMQ.Req' -> 'ZMQ.Rep' (Request-reply pattern)
--
-- >  Server: ZMQ.Rep
-- >  SendType:     a -> (a -> IO a)
-- >  ReceiveType: (a -> IO a) -> IO ()
-- >  ReceiveOptions: RepReceive
--
--    Request reply pattern, that guarantees continuation of the process,
--    this pattern has following limitations: 1). reply type is the same as
--    request type, all actions is done in IO, but should be in a process.

instance ChannelPair ZMQ.Pub  ZMQ.Sub
instance ChannelPair ZMQ.Push ZMQ.Pull
instance ChannelPair ZMQ.Req  ZMQ.Rep
instance ChannelPair ZMQ.Dealer ZMQ.Rep
instance ChannelPair ZMQ.Dealer ZMQ.Router
instance ChannelPair ZMQ.Dealer ZMQ.Dealer
instance ChannelPair ZMQ.Router ZMQ.Router
instance ChannelPair ZMQ.Pair   ZMQ.Pair

type SocketAddress = ByteString

-- | Ticket for input channel.
data ChanAddrIn  t a = ChanAddrIn  (SocketIn t)  SocketAddress deriving (Generic, Typeable)

instance (Binary (SocketIn s), Binary a) => Binary (ChanAddrIn s a)

-- | Ticket for output channel. 
data ChanAddrOut t a = ChanAddrOut (SocketOut t) SocketAddress deriving (Generic, Typeable)

instance (Binary (SocketOut s), Binary a) => Binary (ChanAddrOut s a)

-- | Wrapper for ZeroMQ socket it allows overriding Serialization
-- properties.
newtype SocketIn s = SocketIn s

instance Binary (SocketIn ZMQ.Pull) where
  put _ = return () 
  get   = return $ SocketIn ZMQ.Pull

newtype SocketOut a = SocketOut a

instance Binary (SocketOut ZMQ.Sub) where
  put _ = return () 
  get   = return $ SocketOut ZMQ.Sub

data PairOptions  = PairOptions
      { poAddress :: Maybe ByteString -- ^ Override transport socket address.
      }

-- | Create socket pair. This function returns a \'tickets\' that can be
-- converted into a real sockets by 'registerSend' or 'registerReceive'
-- functions. User should covert local (server) \'ticket\' into socket
-- immediatelly, so remote side can connect to it.
pair :: ChannelPair t1 t2
     => (t1, t2)      -- ^ Socket types.
     -> PairOptions   -- ^ Configuration options.
     -> Process (ChanAddrIn t1 a, ChanAddrOut t2 a)
pair (si,so) o = case poAddress o of
   Just addr -> return (ChanAddrIn (SocketIn si) addr, ChanAddrOut (SocketOut so) addr)
   Nothing   -> error "Not yet implemented." 

-- | Create output channel, when remote side is outside distributed-process
-- cluster. 
singleOut :: (ChannelPair t1 t2, Serializable (ChanAddrIn t1 a))
          => t1
          -> t2
          -> SocketAddress
          -> ChanAddrOut t1 a
singleOut so _ addr = ChanAddrOut (SocketOut so) addr

-- | Create input channel, when remote side is outside distributed-process
-- cluster.
singleIn :: (ChannelPair t1 t2, Serializable (ChanAddrOut t2 a))
         => t1
         -> t2
         -> SocketAddress
         -> ChanAddrIn t2 a
singleIn _ si addr = ChanAddrIn (SocketIn si) addr

---------------------------------------------------------------------------------
-- Receive socket instances
---------------------------------------------------------------------------------

instance ChannelReceive (ChanAddrOut ZMQ.Sub) where
  type ReceiveTransport (ChanAddrOut ZMQ.Sub)   = TransportInternals
  type ReceiveResult    (ChanAddrOut ZMQ.Sub) a = a
  data ReceiveOptions   (ChanAddrOut ZMQ.Sub)   = SubReceive (NonEmpty ByteString)
  registerReceive t (SubReceive sbs) ch@(ChanAddrOut _ addr) = liftIO $
    withMVar (transportState t) $ \case
      TransportValid v -> do
          q <- newTQueueIO
          s <- ZMQ.socket (v^.transportContext) ZMQ.Sub
          ZMQ.connect s (B8.unpack addr)
          Foldable.mapM_ (ZMQ.subscribe s) sbs
          tid <- Async.async $ forever $ do
              lst <- if ("" :| []) == sbs
                     then ZMQ.receiveMulti s
                     else fmap Prelude.tail $ ZMQ.receiveMulti s
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
  type ReceiveTransport (ChanAddrOut ZMQ.Pull)   = TransportInternals
  type ReceiveResult    (ChanAddrOut ZMQ.Pull) a = a
  data ReceiveOptions   (ChanAddrOut ZMQ.Pull)   = PullReceive 
  registerReceive t PullReceive ch@(ChanAddrOut _ addr) = liftIO $
    withMVar (transportState t) $ \case
      TransportValid v -> do
        q <- newTQueueIO
        s <- ZMQ.socket (v ^. transportContext) ZMQ.Pull
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
  type ReceiveTransport (ChanAddrOut ZMQ.Rep)   = TransportInternals
  type ReceiveResult    (ChanAddrOut ZMQ.Rep) a = (a -> IO a) -> IO ()
  data ReceiveOptions   (ChanAddrOut ZMQ.Rep)   = ReqReceive
  registerReceive t ReqReceive ch@(ChanAddrOut _ addr) = liftIO $
    withMVar (transportState t) $ \case
      TransportValid v -> do
        req <- newEmptyTMVarIO
        rep <- newEmptyTMVarIO
        s <- ZMQ.socket (v ^. transportContext) ZMQ.Rep
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
    type SendTransport (ChanAddrIn ZMQ.Pub)   = TransportInternals
    type SendValue     (ChanAddrIn ZMQ.Pub) a = (ByteString, a)
    registerSend t (ChanAddrIn _ addr) = liftIO $ 
      withMVar (transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (v ^. transportContext) ZMQ.Pub
          st <- registerSocket v s
          ZMQ.bind s (B8.unpack addr)
          return . Just $ SendPortEx
            { sendEx = \(p,a) -> liftIO $ sendInner t st (encodeListPrefix [p] a)
            , closeSendEx = liftIO $ closeSocket t st
            }
        TransportClosed -> return Nothing 

instance ChannelSend (ChanAddrIn ZMQ.Push) where
    type SendTransport (ChanAddrIn ZMQ.Push)   = TransportInternals
    type SendValue     (ChanAddrIn ZMQ.Push) a = a
    registerSend t (ChanAddrIn _ addr) = liftIO $
      withMVar (transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (v ^. transportContext) ZMQ.Push
          st <- registerSocket v s
          ZMQ.bind s (B8.unpack addr)
          return . Just $ SendPortEx 
            { sendEx = liftIO . (sendInner t st . encodeList')
            , closeSendEx = liftIO $ closeSocket t st
            }
        TransportClosed -> return Nothing 

instance ChannelSend (ChanAddrIn ZMQ.Req) where
    type SendTransport (ChanAddrIn ZMQ.Req)   = TransportInternals
    type SendValue     (ChanAddrIn ZMQ.Req) a = (a, a -> IO ())
    registerSend t ch@(ChanAddrIn _ addr) = liftIO $ 
      withMVar (transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (v^.transportContext) ZMQ.Req
          st <- registerSocket v s
          ZMQ.connect s (B8.unpack addr)
          return . Just $ SendPortEx 
            { sendEx = \(a, fa) -> liftIO $ do
                ex <- sendInner t st (encodeList' a)
                case ex of 
                  Right _ -> do
                    xbs <- ZMQ.receiveMulti s
                    fa $ decodeList' (mkProxyChIn ch) xbs
                    return $ Right ()
                  Left e -> return $ Left e
            , closeSendEx = liftIO $ closeSocket t st
            }
        TransportClosed -> return Nothing 

-----------------------------------------------------------------------
-- Misc
-----------------------------------------------------------------------

mkProxyChIn :: ChanAddrIn x a -> Proxy1 a
mkProxyChIn _ = Proxy1

mkProxyChOut :: ChanAddrOut x a -> Proxy1 a
mkProxyChOut _ = Proxy1


decodeList' :: Binary a => Proxy1 a -> [ByteString] -> a
decodeList' _ = decode . BL.fromChunks

encodeListPrefix :: Binary a => [ByteString] -> a -> NonEmpty ByteString
encodeListPrefix [] x     = encodeList' x
encodeListPrefix (p:ps) x = p :| ps ++ BL.toChunks (encode x)
--  | B8.null p = encodeListPrefix ps x
--  | otherwise = p :| (ps++BL.toChunks (encode x))

encodeList' :: Binary a => a -> NonEmpty ByteString
encodeList' x = case BL.toChunks (encode x) of
   [] -> error "encodeList'"
   (b:bs) -> b :| bs
