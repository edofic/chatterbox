{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

module Lib
( Config(..)
, ConfigPeers(..)
, runNode
) where

import           Data.Binary (Binary)
import           Control.Concurrent (forkIO, threadDelay)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
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
import           GHC.Generics (Generic)


data Config = Config
  { host :: String
  , port :: String
  , peersConfig :: ConfigPeers
  } deriving (Eq, Show)

data ConfigPeers = ConfigPeersAuto
                 | ConfigPeersFile FilePath
                 deriving (Eq, Show)


data AppState = AppState
  { msg :: String
  , readPeers :: IO [P.NodeId]
  }


data Msg = Incoming String
         | Tick
         deriving (Eq, Show, Generic)

instance Binary Msg


runNode :: Config -> IO ()
runNode config@(Config {..}) = do
  let msg = "hello from " ++ host ++ ":" ++ port
  debugM rootLoggerName $ "Using config: " ++ show config

  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend
  selfNodeId <- runProcess' node P.getSelfNode
  readPeers <- loadPeers peersConfig backend selfNodeId

  runProcess node $ do
    registerReceiver
    _ <- P.spawnLocal $ forever $ do
      liftIO $ threadDelay 1000000
      P.nsend "worker" Tick

    let initialState = AppState msg readPeers
    P.getSelfPid >>= P.register "worker"
    mainLoop initialState


loadPeers :: ConfigPeers -> Backend -> P.NodeId -> IO (IO [P.NodeId])
loadPeers ConfigPeersAuto backend selfNodeId = do
  peersRef <- newIORef []
  _ <- forkIO $ forever $ do
    peers <- findPeers backend 1000000
    let peers' = filter (selfNodeId /=) peers
    writeIORef peersRef peers'
    debugM rootLoggerName $ "found " ++ show (length peers') ++ " peers"
  return $ readIORef peersRef
loadPeers (ConfigPeersFile peersFile) _ selfNodeId = do
  rawJson <- BS.readFile peersFile
  case eitherDecode' rawJson of
    Left err -> error $ "Cannot read " ++ peersFile ++ " : " ++ err
    Right rawPeers -> return $ return $ filter (selfNodeId /=) $ map packPeer rawPeers
  where
    packPeer = P.NodeId . EndPointAddress . BSC.pack


mainLoop :: AppState -> P.Process ()
mainLoop state = do
  msg <- P.expect
  state' <- update msg state
  mainLoop state'


update :: Msg -> AppState -> P.Process AppState
update Tick state@AppState{..} = do
  pingerStep readPeers msg
  return state
update (Incoming msg) state = do
  liftIO $ debugM rootLoggerName $ "received :" ++ msg
  return state


registerReceiver :: P.Process ()
registerReceiver = do
  selfNodeId <- P.getSelfNode
  liftIO $ debugM rootLoggerName $ "receiving on " ++ show selfNodeId
  pid <- P.spawnLocal receiver
  P.register "listener" pid


receiver :: P.Process ()
receiver  = forever $ do
  msg <- P.expect
  P.nsend "worker" $ Incoming msg


pingerStep :: IO [P.NodeId] -> String -> P.Process ()
pingerStep readPeers msg = do
  peers <- liftIO $ readPeers
  pingPeers peers msg


pingPeers :: (Foldable t) => t P.NodeId -> String -> P.Process ()
pingPeers peers msg = forM_ peers $ \peer -> do
  liftIO $ debugM rootLoggerName $ "sending to " ++ show peer
  P.nsendRemote peer "listener" msg


runProcess' :: LocalNode -> P.Process a -> IO a
runProcess' node process = do
  var <- newEmptyMVar
  runProcess node $ do
    res <- process
    liftIO $ putMVar var res
  readMVar var
