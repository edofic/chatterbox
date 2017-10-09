module Lib
( runNode
) where

import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Node (LocalNode, initRemoteTable, runProcess)
import           Control.Monad (forever, forM_)
import           Control.Monad.IO.Class (liftIO)
import qualified Control.Distributed.Process as P


runNode :: String -> String -> IO ()
runNode host port = do
  let msg = "hello from " ++ host ++ ":" ++ port

  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend

  runProcess node registerReceiver
  forever $ pingerStep backend node msg


registerReceiver :: P.Process ()
registerReceiver = do
  pid <- P.spawnLocal $ forever $ do
    msg <- P.expect :: P.Process String
    liftIO $ putStrLn $ "received: " ++ msg
  P.register "worker" pid


pingerStep :: Backend -> LocalNode -> String -> IO ()
pingerStep backend node msg = do
  peers   <- findPeers backend 1000000
  putStrLn $ "found " ++ show (length peers) ++ " peers"
  runProcess node $ do
    pingPeers peers msg
    liftIO $ putStrLn ""


pingPeers :: (Foldable t) => t P.NodeId -> String -> P.Process ()
pingPeers peers msg = forM_ peers $ \peer -> do
  liftIO $ putStrLn $ "sending to " ++ show peer
  P.nsendRemote peer "worker" msg
