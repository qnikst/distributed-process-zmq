-- | Distributed Process 0MQ backend allow to use network-transport-zmq and
-- provides additional functionallity that uses 0mq channels.
--
module Control.Distributed.Process.Backend.ZMQ 
  ( fakeTransport
  , module Control.Distributed.Process.Backend.ZMQ.Channel
  , ReceivePortEx(..)
  , SendPortEx(..)
  ) where

import           Control.Applicative
import           Control.Concurrent
      ( newMVar 
      )
import           Data.ByteString
      ( ByteString
      )
import qualified Data.Map as Map

import           Control.Distributed.Process.ChannelEx
import           Control.Distributed.Process.Backend.ZMQ.Channel
import           Network.Transport.ZMQ.Types
import qualified System.ZMQ4 as ZMQ

-- | Simplified version of 0MQ transport, this function can be used when
-- network-transport-zmq is not used as a distributed-process channel.
fakeTransport :: ByteString -> IO ZMQTransport
fakeTransport bs = ZMQTransport
  <$> pure bs 
  <*> (newMVar =<< (TransportValid <$> (ValidTransportState <$> ZMQ.context
                                                            <*> pure Map.empty)))

