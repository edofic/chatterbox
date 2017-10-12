{-# LANGUAGE RecordWildCards #-}

module Lib
( Config(..)
, ConfigPeers(..)
, runNode
) where

import           Control.Concurrent (forkIO, threadDelay)
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Node (LocalNode, initRemoteTable, runProcess)
import           Control.Monad (forever, forM_)
import           Control.Monad.IO.Class (liftIO)
import           Data.Aeson (eitherDecode')
import           Data.IORef
import           Network.Transport (EndPointAddress(EndPointAddress))
import           System.Log.Logger (debugM, rootLoggerName)
import qualified Control.Distributed.Process as P
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BS


data Config = Config
  { host :: String
  , port :: String
  , peersConfig :: ConfigPeers
  } deriving (Eq, Show)

data ConfigPeers = ConfigPeersAuto
                 | ConfigPeersFile FilePath
                 deriving (Eq, Show)

runNode :: Config -> IO ()
runNode config@(Config {..}) = do
  let msg = "hello from " ++ host ++ ":" ++ port
  debugM rootLoggerName $ "Using config: " ++ show config

  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend
  peersRef <- loadPeers peersConfig backend


  runProcess node registerReceiver
  forever $ do
    pingerStep peersRef node msg
    threadDelay 1000000


loadPeers :: ConfigPeers -> Backend -> IO (IORef [P.NodeId])
loadPeers ConfigPeersAuto backend = do
  peersRef <- newIORef []
  _ <- forkIO $ forever $ do
    peers <- findPeers backend 1000000
    writeIORef peersRef peers
    debugM rootLoggerName $ "found " ++ show (length peers) ++ " peers"
  return peersRef
loadPeers (ConfigPeersFile peersFile) _ = do
  rawJson <- BS.readFile peersFile
  case eitherDecode' rawJson of
    Left err -> error $ "Cannot read " ++ peersFile ++ " : " ++ err
    Right rawPeers -> newIORef $ map packPeer rawPeers
  where
    packPeer = P.NodeId . EndPointAddress . BSC.pack


registerReceiver :: P.Process ()
registerReceiver = do
  selfNodeId <- P.getSelfNode
  liftIO $ debugM rootLoggerName $ "receiving on " ++ show selfNodeId
  pid <- P.spawnLocal $ forever $ do
    msg <- P.expect :: P.Process String
    liftIO $ debugM rootLoggerName $ "received: " ++ msg
  P.register "worker" pid


pingerStep :: IORef [P.NodeId] -> LocalNode -> String -> IO ()
pingerStep peersRef node msg = do
  peers <- readIORef peersRef
  runProcess node $ pingPeers peers msg


pingPeers :: (Foldable t) => t P.NodeId -> String -> P.Process ()
pingPeers peers msg = forM_ peers $ \peer -> do
  liftIO $ debugM rootLoggerName $ "sending to " ++ show peer
  P.nsendRemote peer "worker" msg
