{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where


import Control.Concurrent
import Control.Exception (SomeException)
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Distributed.Process.Backend.ZMQ
import Control.Monad
import Data.List.NonEmpty
import Network.Transport.ZMQ.Types
import Network.Transport.TCP

import System.ZMQ4
import Text.Printf

test :: ZMQTransport -> Process ()
test transport = do
  -- Pub->Sub
  (chIn, chOut) <- pair (Pub, Sub) (PairOptions (Just "tcp://127.0.0.1:5423"))
  Just port <- liftIO $ registerSend transport chIn
  replicateM 10 $ spawnLocal $ do
      us <- getSelfPid
      Just ch <- liftIO $ registerReceive transport (SubReceive ("":|[])) chOut
      x <- try $ replicateM_ 10 $ do
        v  <- receiveChan ch
        liftIO $ printf "[%s] %i\n" (show us) (v::Int)
      case x of
        Right _ -> return ()
        Left e  -> liftIO $ print (e::SomeException)
  liftIO $ threadDelay 1000000
  mapM_ (liftIO . sendEx port) [1..100::Int]
  -- Push->Pull                
  liftIO $ putStrLn "PushPull"
  (chIn1, chOut1) <- pair (Push,Pull) (PairOptions (Just "tcp://127.0.0.1:5789"))
  Just port1 <- liftIO $ registerSend transport chIn1
  replicateM 10 $ spawnLocal $ do
      us <- getSelfPid
      Just ch <- liftIO $ registerReceive transport PullReceive chOut1
      liftIO $ yield
      x <- try $ replicateM_ 100 $ do
        v  <- receiveChan ch
        liftIO $ printf "[%s] %i\n" (show us) (v::Int)
      case x of
        Right _ -> return ()
        Left e  -> liftIO $ print (e::SomeException)
  liftIO $ yield
  liftIO $ threadDelay 1000000
  mapM_ (\i -> do liftIO $ putStr ":" >>  sendEx port1 i) [1..100::Int]
  liftIO $ threadDelay 1000000
  -- Req-Rep
  liftIO $ putStrLn "ReqRep"
  (chIn2, chOut2) <- pair (Req, Rep) (PairOptions (Just "tcp://127.0.0.1:5424"))
  replicateM_ 10 $ spawnLocal $ do
      us <- getSelfPid
      Just ch <- liftIO $ registerSend transport chIn2 
      liftIO $ sendEx ch (show us, print)
      return ()
  Just ch <- liftIO $ registerReceive transport ReqReceive chOut2
  replicateM_ 10 $ do
    f <- receiveChanEx ch
    liftIO $ f (\x -> return $ Prelude.reverse x)


main = do
  zmq             <- fakeTransport "localhost"
  Right transport <- createTransport "localhost" "8232" defaultTCPParameters
  node <- newLocalNode transport initRemoteTable
  runProcess node $ test zmq

