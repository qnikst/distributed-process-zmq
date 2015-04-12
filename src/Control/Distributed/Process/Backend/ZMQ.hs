{-# LANGUAGE OverloadedStrings #-}
-- | 
-- Module:    Control.Distributed.Process.Backend.ZMQ
-- Copyright: 2014 (C) EURL Tweag
-- License:   BSD-3
--
-- Distributed Process ZeroMQ backend allow to use network-transport-zmq and
-- provides additional functionallity that uses ZeorMQ channels.
--
module Control.Distributed.Process.Backend.ZMQ 
  ( 
  -- fakeTransport
  -- * Extended channels
  -- $channels-doc
  -- ** Construction
  pair
  , PairOptions(..)
  , singleIn
  , singleOut
  -- ** Usage
  , registerSend
  , registerReceive
  , receiveChanEx
  , closeReceiveEx
  , sendEx
  , closeSendEx
  , ReceiveOptions(..)
  ) where

import           Control.Applicative
import           Control.Concurrent
      ( newMVar 
      )
import           Data.IORef
import qualified Data.IntMap as IntMap
import qualified Data.Map as Map

import           Control.Distributed.Process.ChannelEx
import           Control.Distributed.Process.Backend.ZMQ.Channel
import           Network.Transport.ZMQ.Internal.Types
import qualified System.ZMQ4 as ZMQ

{- 
-- | Simplified version of ZeroMQ transport, this function can be used when
-- network-transport-zmq is not used as a distributed-process channel.
fakeTransport :: IO TransportInternals
fakeTransport = TransportInternals
  <$> pure "Simplified version does not have address" 
  <*> (newMVar =<< (TransportValid <$> (ValidTransportState <$> ZMQ.context
                                                            <*> pure Map.empty
                                                            <*> pure Nothing
                                                            <*> newIORef IntMap.empty)))
-}

-- $channels-doc
-- For more information on extended channels refer to
-- "Control.Distributed.Process.ChannelEx" (general information) and
-- "Control.Distributed.Process.Backend.ZMQ.Channel" (ZeroMQ specific
-- information).
