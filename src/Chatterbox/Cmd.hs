{-# LANGUAGE NamedFieldPuns #-}

module Chatterbox.Cmd where

import           Control.Concurrent (threadDelay)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Writer.Strict (Writer, tell)
import           System.Log.Logger (debugM, rootLoggerName)
import qualified Control.Distributed.Process as P
import qualified Data.Sequence as Seq

import Chatterbox.Types

data Cmd = Log String
         | Print String
         | Send P.NodeId RemoteMsg
         | TriggerStopTimer
         | TriggerQuitTimer
         | WakeUpTicker

cmd :: Cmd -> Writer (Seq.Seq Cmd) ()
cmd = tell . Seq.singleton

runCmd :: LoopConfig -> Cmd -> P.Process ()
runCmd _ (Log msg) = liftIO $ debugM rootLoggerName msg
runCmd _ (Print msg) = liftIO $ putStrLn msg
runCmd _ (Send nodeId msg) = P.nsendRemote nodeId "listener" msg
runCmd _ WakeUpTicker = P.nsend "ticker" ()
runCmd LoopConfig{sendForDelay} TriggerStopTimer = do
  _ <- P.spawnLocal $ do
    liftIO $ threadDelay sendForDelay
    P.nsend "worker" Stop
  return ()
runCmd LoopConfig{waitForDelay} TriggerQuitTimer = do
  _ <- P.spawnLocal $ do
    liftIO $ threadDelay waitForDelay
    P.nsend "worker" Quit
  return ()

