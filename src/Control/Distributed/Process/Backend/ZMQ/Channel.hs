{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE TypeFamilies #-}
-- | Module provides an extended version of channels.
--
-- Technitial depts:
--
--    [ ] correct socket close
--
--    [ ] correct transport close
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
    SocketPair
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

import           Control.Applicative
import qualified Control.Concurrent.Async as Async
import           Control.Concurrent.STM
import           Control.Concurrent.STM.TQueue
import           Control.Concurrent.MVar
import           Control.Distributed.Process
import           Control.Distributed.Process.Serializable
import           Control.Distributed.Process.Internal.Types
import qualified Control.Exception as Exception
import           Control.Monad
      ( forever 
      )
import           Control.Monad.IO.Class
import           Data.Binary
import           Data.ByteString
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Char8 as B8
import qualified Data.Foldable as Foldable
import           Data.List.NonEmpty
      ( NonEmpty(..)
      )
import qualified Data.List.NonEmpty as NonEmpty
import           Data.Typeable
import qualified Data.Map as Map

import           GHC.Generics
import qualified System.ZMQ4 as ZMQ
import           Network.Transport
import           Network.Transport.ZMQ
import           Network.Transport.ZMQ.Types

import           Control.Distributed.Process.Backend.ZMQ.Missing

data Proxy1 a = Proxy1

-- $channel-pairs
-- Channel pairs provides type safe way to create a pair of sockets 
-- the instances and handle all internal information that is required
-- to handle such channels.


-- | List of available socket pairs.
class SocketPair a b

instance SocketPair ZMQ.Pub  ZMQ.Sub
instance SocketPair ZMQ.Push ZMQ.Pull
instance SocketPair ZMQ.Req  ZMQ.Rep
-- instance SocketPair Dealer Rep
-- instance SocketPair Dealer Router
-- instance SocketPair Dealer Dealer
-- instance SocketPair Router Router
-- instance SocketPair Pair Pair

-- | Helper proxy type
data Proxy a = Proxy

type SocketAddress = ByteString

data ChanAddrIn  t a = ChanAddrIn SocketAddress deriving (Generic, Typeable)
data ChanAddrOut t a = ChanAddrOut SocketAddress deriving (Generic, Typeable)

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

-- | Extended send port provides an additional functionatility to 
-- 'SendPort' as a result it allow to overload send function with
-- new logic, and make it much more flexible.
data SendPortEx a = SendPortEx
       { sendEx :: a -> IO (Either (TransportError SendErrorCode) ()) }
      

data PairOptions  = PairOptions
      { poAddress :: Maybe ByteString -- ^ Override transport socket address.
      }

-- | Create socket pair. This function returns a \'tickets\' that can be
-- converted into a real sockets with 'registerSend' or 'registerReceive'.
-- User will have to covert local \'ticket\' into socket immediatelly,
-- so remote side can connect to it.
pair :: SocketPair t1 t2
     => (t1, t2)      -- ^ Socket types,
     -> PairOptions   -- ^ Configuration options.
     -> Process (ChanAddrIn t1 a, ChanAddrOut t2 a)
pair _ o = case poAddress o of
   Just addr -> return (ChanAddrIn addr, ChanAddrOut addr)
   Nothing   -> error "Not yet implemented." 

-- | Create output channel, when remote side is outside distributed-process
-- cluster. Serializable restriction says that the return type of socket is
-- a \'client\' for remote server.
singleOut :: (SocketPair t1 t2, Serializable (ChanAddrIn t1 a))
          => t1
          -> t2
          -> SocketAddress
          -> ChanAddrOut t2 a
singleOut _ _ addr = ChanAddrOut addr

-- | Create input channel, when remote side is outside distributed-process
-- cluster
singleIn :: (SocketPair t1 t2, Serializable (ChanAddrOut t2 a))
         => t1
         -> t2
         -> SocketAddress
         -> ChanAddrIn t2 a
singleIn _ _ addr = ChanAddrIn addr

class SocketReceive (x :: * -> *) where
  data ReceiveOptions x  :: *
  type ReceiveResult x y :: *
  -- | Create receive socket.
  registerReceive :: Serializable a 
                  => ZMQTransport
                  -> ReceiveOptions x
                  -> x a
                  -> Process (Maybe (ReceivePort (ReceiveResult x a)))

class SocketSend (x :: * -> *) where
  type SendValue x y :: *
  registerSend :: Serializable a 
              => ZMQTransport 
              -> x a 
              -> Process (Maybe (SendPortEx (SendValue x a)))

---------------------------------------------------------------------------------
-- Receive socket instances
---------------------------------------------------------------------------------

instance SocketReceive (ChanAddrOut ZMQ.Sub) where
  data ReceiveOptions (ChanAddrOut ZMQ.Sub)  = SubReceive (NonEmpty ByteString)
  type ReceiveResult (ChanAddrOut ZMQ.Sub) a = a
  registerReceive t (SubReceive sbs) ch@(ChanAddrOut address) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
          q <- newTQueueIO
          s <- ZMQ.socket (_transportContext v) ZMQ.Sub
          ZMQ.connect s (B8.unpack address)
          Foldable.mapM_ (ZMQ.subscribe s) sbs
          Async.async $ do
            x <- Exception.try $ forever $ do
              lst <- ZMQ.receiveMulti s
              atomically $ writeTQueue q (decodeList' (mkProxy1 ch) lst)
            case x of
              Left e -> print (e::Exception.SomeException)
              Right _ -> return ()
          return . Just $ ReceivePort $ readTQueue q
      TransportClosed -> return Nothing
    where
      mkProxy1 :: ChanAddrOut x a -> Proxy1 a
      mkProxy1 _ = Proxy1

instance SocketReceive (ChanAddrOut ZMQ.Pull) where
  data ReceiveOptions (ChanAddrOut ZMQ.Pull) = PullReceive 
  type ReceiveResult (ChanAddrOut ZMQ.Pull) a = a
  registerReceive t PullReceive ch@(ChanAddrOut address) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
        q <- newTQueueIO
        s <- ZMQ.socket (_transportContext v) ZMQ.Pull
        ZMQ.connect s (B8.unpack address)
        Async.async $ do
          x <- Exception.try $ forever $ do
              lst <- ZMQ.receiveMulti s
              atomically $ writeTQueue q (decodeList' (mkProxy1 ch) lst)
          case x of
            Left e  -> print (e::Exception.SomeException)
            Right _ -> return ()
        return . Just $ ReceivePort $ readTQueue q
      TransportClosed -> return Nothing
    where
      mkProxy1 :: ChanAddrOut x a -> Proxy1 a
      mkProxy1 _ = Proxy1

instance SocketReceive (ChanAddrOut ZMQ.Rep) where
  data ReceiveOptions (ChanAddrOut ZMQ.Rep)   = ReqReceive
  type ReceiveResult  (ChanAddrOut ZMQ.Rep) a = (a -> IO a) -> IO ()
  registerReceive t ReqReceive ch@(ChanAddrOut address) = liftIO $
    withMVar (_transportState t) $ \case
      TransportValid v -> do
        req <- newEmptyTMVarIO
        rep <- newEmptyTMVarIO
        s <- ZMQ.socket (_transportContext v) ZMQ.Rep
        ZMQ.bind s (B8.unpack address)
        Async.async $ do
          x <- Exception.try $ forever $ do
                lst <- ZMQ.receiveMulti s
                atomically $ putTMVar req $ \f -> do 
                    y <- f $ decodeList' (mkProxy1 ch) lst
                    liftIO $ atomically $ putTMVar rep $ encodeList' y
                ZMQ.sendMulti s =<< (atomically $ takeTMVar rep)
          case x of
            Left e  -> print (e::Exception.SomeException)
            Right _ -> return ()
        return . Just $ ReceivePort $ takeTMVar req
      TransportClosed -> return Nothing
    where
      mkProxy1 :: ChanAddrOut x a -> Proxy1 a
      mkProxy1 _ = Proxy1

---------------------------------------------------------------------------------
-- Send socket instances
---------------------------------------------------------------------------------

instance SocketSend (ChanAddrIn ZMQ.Pub) where
    type SendValue (ChanAddrIn ZMQ.Pub) a = a
    registerSend t (ChanAddrIn address) = liftIO $ 
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Pub
          ZMQ.bind s (B8.unpack address)
          s' <- ZMQSocket <$> newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx $ sendInner t s'
        TransportClosed -> return Nothing 

instance SocketSend (ChanAddrIn ZMQ.Push) where
    type SendValue (ChanAddrIn ZMQ.Push) a = a
    registerSend t (ChanAddrIn address) = liftIO $
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Push
          ZMQ.bind s (B8.unpack address)
          s' <- ZMQSocket <$> newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx $ sendInner t s'
        TransportClosed -> return Nothing 

instance SocketSend (ChanAddrIn ZMQ.Req) where
    type SendValue (ChanAddrIn ZMQ.Req) a = (a, a -> IO ())
    registerSend t ch@(ChanAddrIn address) = liftIO $ 
      withMVar (_transportState t) $ \case
        TransportValid v -> do
          s <- ZMQ.socket (_transportContext v) ZMQ.Req
          ZMQ.connect s (B8.unpack address)
          s' <- ZMQSocket <$> newMVar (ZMQSocketValid (ValidZMQSocket s))
          return . Just $ SendPortEx $ \(a, fa) -> do
            ex <- sendInner t s' a
            case ex of 
              Right _ -> do xbs <- ZMQ.receiveMulti s
                            fa $ decodeList' (mkProxy1 ch) xbs
                            return $ Right ()
              Left e -> return $ Left e
        TransportClosed -> return Nothing 
      where
        mkProxy1 :: ChanAddrIn x a -> Proxy1 a
        mkProxy1 _ = Proxy1

sendInner :: (ZMQ.Sender s, Serializable a) => ZMQTransport -> ZMQSocket (ZMQ.Socket s) -> a -> IO (Either (TransportError SendErrorCode) ())
sendInner transport socket msg = withMVar (socketState socket) $ \case
  ZMQSocketValid (ValidZMQSocket s) -> withMVar (_transportState transport) $ \case
    TransportValid{} -> ZMQ.sendMulti s (encodeList' msg) >> return (Right ())
    TransportClosed  -> return $ Left $ TransportError SendFailed "Transport is closed."
  ZMQSocketClosed  -> return $ Left $ TransportError SendClosed "Socket is closed."

-- | Like 'receiveChan' but doesn't have Binary restriction over value.
receiveChanEx :: ReceivePort x -> Process x
receiveChanEx (ReceivePort f) = liftIO $ atomically f

decodeList' :: Binary a => Proxy1 a -> [ByteString] -> a
decodeList' _ = decode . BL.fromChunks

encodeList' :: Binary a => a -> NonEmpty ByteString
encodeList' x = case BL.toChunks (encode x) of
   [] -> error "encodeList'"
   (b:bs) -> b :| bs

