{-# LANGUAGE OverloadedStrings, TemplateHaskell #-}
module Main
  where

import Control.Concurrent
import Control.Exception (SomeException)
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Node
import Control.Distributed.Process.Backend.ZMQ
import Control.Distributed.Process.Backend.ZMQ.Channel
import Control.Monad
import qualified Data.ByteString.Char8 as B8
import Data.Typeable
import Data.List.NonEmpty
import Network.Transport.ZMQ.Internal.Types as NTZ
import Network.Transport.TCP

import System.Random
import qualified System.ZMQ4 as ZMQ
import Text.Printf

server :: NTZ.TransportInternals -> Process ()
server transport = forever $ do
    (chIn, chOut) <- pair (ZMQ.Pub, ZMQ.Sub) (PairOptions (Just "tcp://127.0.0.1:5423"))
    Just port <- registerSend transport (chIn :: ChanAddrIn ZMQ.Pub (Int,Int))
    -- create thread that will produce information
    spawnLocal $ forever $ do
        zipcode     <- liftIO $ randomRIO (  0, 1000000::Int)
        temperature <- liftIO $ randomRIO (-80, 135::Int)
        humidity    <- liftIO $ randomRIO ( 10, 60::Int)
        sendEx port ((B8.pack (show zipcode)),(temperature,humidity))
    forever $ do
      pid <- expect
      send pid chOut

client :: NTZ.TransportInternals -> ProcessId -> MVar () -> Process ()
client transport pid end = do
  me <- getSelfPid
  send pid me
  chOut <- expect :: Process (ChanAddrOut ZMQ.Sub (Int,Int))
  Just ch <- registerReceive transport (SubReceive ("10001":|[])) chOut
  records <- replicateM 5 $ receiveChanEx ch :: Process [(Int,Int)]
  liftIO $ do
    print records
    putMVar end ()

main = do
  zmq             <- fakeTransport
  Right transport <- createTransport "localhost" "8232" defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  end <- newEmptyMVar
  runProcess node $ do
    srv <- spawnLocal (server zmq)
    spawnLocal (client zmq srv end)
    liftIO $ takeMVar end
