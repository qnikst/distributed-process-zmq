-- | 
-- Module:    Control.Distributed.Process.ChannelEx
-- Copyright: 2014 (C) EURL Tweag
-- License:   BSD-3
--
-- This module provides an extended version of
-- 'Control.Ditributed.Process.Channel's that are type indexed
-- and allow action overloading. Such channels can expose additional
-- functionality provided by network-transport.
--
-- Basically this module provides channel based approach to build
-- distributed systems, while actor based approach is more general (as we
-- could always wrap channel with actor), channel based approach is more
-- explit. This allow to build easily maintainable and scalable systems 
-- and ability to connect distributed-process haskell to the outer world.
-- 
-- At the simpliest level extendend channels create an additional endpoint
-- and heavyweight (physical) connection between such endpoints. However
-- this is implementation dependent and for some types of channels
-- connections may be lightweight or even reuse basic network-transport
-- connections. 
--
-- Such channels may have different properties like different
-- reliability, serialization, perform connection authorization or encryption
-- or even use other drivers to create a connection or type of sockets.
--
-- Note. While this approach is under development it's in distributed-process-zmq
-- package, as 0mq is the main consumer of this functionality, however in
-- future it may be moved to another package.
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
module Control.Distributed.Process.ChannelEx 
  ( SendPortEx(..)
  , ReceivePortEx(..)
  , receiveChanEx
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

-- | List of available socket pairs, some types of sockets/channels may
-- be imcompatible with each other, 'ChannelPair' class enumerates all
-- channels that are compatible with each other. 
--
-- 'ChannelPair' typeclass is open because each network transport implementation
-- may add new types of sockets and rules, but in it's not safe to use this
-- class outside d-p-impl package, as it may break guarantees.
class ChannelPair i o

-- | Extended send port provides an additional functionatility to 
-- 'SendPort' as a result it allow to overload send function with
-- new logic, and make it much more flexible.
data SendPortEx a = SendPortEx
       { sendEx :: a -> Process (Either (TransportError SendErrorCode) ())  -- ^ Send message.
       , closeSendEx :: Process ()                                          -- ^ Close channel.
       }

-- defaultSendPort :: SendPort a -> SendPortEx a
-- defaultSendPort ch = SendPortEx (sendChan ch)

-- | ReceivePortEx contains old port and close function.
data ReceivePortEx a = ReceivePortEx
      { receiveEx :: ReceivePort a
      , closeReceiveEx :: Process ()
      }

-- | Like 'receiveChan' but doesn't have Binary restriction over value.
receiveChanEx :: ReceivePortEx x -> Process x
receiveChanEx (ReceivePortEx (ReceivePort f) _) = liftIO $ atomically f

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
