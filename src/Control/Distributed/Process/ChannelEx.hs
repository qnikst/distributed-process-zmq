-- | 
-- Module:    Control.Distributed.Process.ChannelEx
-- Copyright: 2014 (C) EURL Tweag
-- License:   BSD-3
--
-- This module provides an extended version of
-- 'Control.Ditributed.Process.Channel's that allow behavior overloading.
-- These channels can expose additional functionality provided by 
-- different network-transport implementations.
--
-- Basically this module provide channel based approach for building
-- distributed systems. This approach can be used together with actor based
-- approach that is provided by DistributedProcess. 
-- Channel based approach explicitly describes network structure and
-- connection properties, that gives a way to build more reliable or
-- scalable systems, with properties that may differ from default
-- properites of the actor cluster. Some examples are:
--
--    * connection authorization;
--
--    * connection encryption;
--
--    * different pattern for channel (load balancing, multicast);
--
--    * different connection properties (reliability);
--
--    * different network-transport.
-- 
-- At the simplest level extendend channels may create an additional endpoint
-- and heavyweight (physical) connection between such endpoints. However
-- this is implementation dependent and for some types of channels
-- connections may be lightweight or even reuse basic network-transport
-- connections. 
--
-- Note. While this approach is under development it's in distributed-process-zmq
-- package, as 0mq is the main consumer of this functionality, however in
-- future it may be moved to another package.
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
module Control.Distributed.Process.ChannelEx 
  ( 
  -- * Channel Types
  -- $channel-types-doc
    SendPortEx(..)
  , ReceivePortEx(..)
  , extendSendPort
  , extendReceivePort
  , receiveChanEx
  -- * Channel Pairs
  -- $channel-pairs-doc
  , ChannelPair
  , ChannelReceive(..)
  , ChannelSend(..)
  ) where

import           Control.Concurrent.STM
      ( atomically
      )
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Distributed.Process.Internal.Types
import           Network.Transport

-- $channel-types-doc
--
-- New channel types provide a very low interface for channels, as a result
-- user should explicitly close them. In the future this interface may be
-- done in a highlevel way like channels in distributed-process.


-- | Extended send port provides an additional functionality to 
-- 'SendPort' as a result it allow to overload send function with
-- new logic, and make it much more flexible.
data SendPortEx a = SendPortEx
       { sendEx :: a -> Process (Either (TransportError SendErrorCode) ())  -- ^ Send message.
       , closeSendEx :: Process ()                                          -- ^ Close channel.
       }

-- | ReceivePortEx provides an additional functionality to 'ReceivePort'.
-- Currently it just wraps plain old 'ReceivePort' in order to make API
-- consistent
data ReceivePortEx a = ReceivePortEx
      { receiveEx :: ReceivePort a                                          -- ^ ReceivePort.
      , closeReceiveEx :: Process ()                                        -- ^ Close channel.
      }

-- | Extend default 'SendPort'.
extendSendPort :: Serializable a => SendPort a -> SendPortEx a
extendSendPort ch = SendPortEx
      { sendEx = \x -> sendChan ch x >> return (Right ())
      , closeSendEx = return ()
      }

-- | Extend default 'ReceivePort'.
extendReceivePort :: ReceivePort a -> ReceivePortEx a
extendReceivePort ch  = ReceivePortEx
    { receiveEx = ch
    , closeReceiveEx = return ()
    }

-- | Like 'receiveChan' but doesn't have 'Serializable' restriction on value.
-- This is required, because 'ReceivePort' may convert received value into
-- the form that is no longer 'Serializable'.
receiveChanEx :: ReceivePortEx x -> Process x
receiveChanEx (ReceivePortEx (ReceivePort f) _) = liftIO $ atomically f

-- $channel-pairs-doc
-- In order to make channels consistent, we need to create a pair of
-- channels, and then pass channels on the other node. However not every
-- pair on extendent channels is consistent. 'ChannelPair' type provides
-- a way to enumerate all consistent pairs.
--
-- 'ChannelPair' typeclass is open because each network transport implementation
-- may add new types of sockets and rules, but in it's not safe to use this
-- class outside distributed-process-\<implementation\> package, as it may break
-- constraints of the underlying transport.
--
-- Creation of sockets in shoud be done in
-- distributed-process-\<implementation\> library. And on the contrary to
-- the 'newChans' this function doesn't guarantee creation of the network
-- sockets, and it may return a "tickets" that may be later registered to
-- the sockets. For this purpose 'ChannelReceive' and 'ChannelSend' were
-- introduced, those classes describes properties on the channels and
-- creates a network sockets when they are being called.

-- | List of available socket pairs, some types of sockets/channels may
-- be imcompatible with each other, 'ChannelPair' class enumerates all
-- channels that are compatible with each other. 
--
class ChannelPair i o

-- | Register receive socket
class ChannelReceive (x :: * -> *) where
  data ReceiveOptions x   :: *
  type ReceiveResult x y  :: *
  type ReceiveTransport x :: *
  -- | Create receive socket.
  registerReceive :: Serializable a 
                  => ReceiveTransport x
                  -> ReceiveOptions x
                  -> x a
                  -> Process (Maybe (ReceivePortEx (ReceiveResult x a)))

class ChannelSend (x :: * -> *) where
  type SendTransport x :: *
  type SendValue x y   :: *
  registerSend :: Serializable a 
              => SendTransport x
              -> x a 
              -> Process (Maybe (SendPortEx (SendValue x a)))
