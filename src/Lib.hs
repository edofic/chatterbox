{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE RecordWildCards #-}

module Lib
( Config(..)
, runNode
) where

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import           Control.Distributed.Process.Node (LocalNode, initRemoteTable, runProcess, newLocalNode)
import           Control.Monad (forever, forM_)
import           Control.Monad.IO.Class (liftIO)
import           Data.Aeson (eitherDecode')
import           Data.Binary (Binary)
import           GHC.Generics (Generic)
import           Network.Transport (EndPointAddress(EndPointAddress))
import           Network.Transport.TCP (createTransport, defaultTCPParameters)
import           System.Log.Logger (debugM, rootLoggerName)
import qualified Control.Distributed.Process as P
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BS
import qualified Data.Set as Set


data Config = Config
  { host :: String
  , port :: String
  , peersFile :: FilePath
  } deriving (Eq, Show)


data LoopConfig = LoopConfig
  { selfNodeId :: P.NodeId
  , peerList :: [P.NodeId]
  }


data AppState = AppState
  { msgStream :: [Integer]
  , received :: Set.Set RemoteMsg
  }


data RemoteMsg = RemoteMsg P.NodeId Integer deriving (Eq, Show, Ord, Generic)

data Msg = Incoming RemoteMsg
         | Tick
         deriving (Eq, Show, Generic)


instance Binary RemoteMsg
instance Binary Msg


runNode :: Config -> IO ()
runNode config@(Config {..}) = do
  let msgStream = [1..]
  debugM rootLoggerName $ "Using config: " ++ show config

  node <- createTransport host port defaultTCPParameters >>= \r -> case r of
    Right transport -> newLocalNode transport initRemoteTable
    Left  err       -> error $ show err

  selfNodeId <- runProcess' node P.getSelfNode
  peerList <- loadPeers peersFile selfNodeId

  runProcess node $ do
    registerReceiver
    _ <- P.spawnLocal $ forever $ do
      liftIO $ threadDelay 1000000
      P.nsend "worker" Tick

    let loopConfig = LoopConfig selfNodeId peerList
        initialState = AppState msgStream Set.empty
    P.getSelfPid >>= P.register "worker"
    mainLoop loopConfig initialState


loadPeers :: FilePath -> P.NodeId -> IO [P.NodeId]
loadPeers peersFile selfNodeId = do
  rawJson <- BS.readFile peersFile
  case eitherDecode' rawJson of
    Left err -> error $ "Cannot read " ++ peersFile ++ " : " ++ err
    Right rawPeers -> return $ filter (selfNodeId /=) $ map packPeer rawPeers
  where
    packPeer = P.NodeId . EndPointAddress . BSC.pack


mainLoop :: LoopConfig -> AppState -> P.Process ()
mainLoop loopConfig state = do
  msg <- P.expect
  state' <- update msg loopConfig state
  mainLoop loopConfig state'


update :: Msg -> LoopConfig -> AppState -> P.Process AppState
update Tick LoopConfig{..} state@AppState{..} = do
  let msg : msgStream' = msgStream
  forM_ peerList $ \peer -> do
    liftIO $ debugM rootLoggerName $ "sending to " ++ show peer
    P.nsendRemote peer "listener" $ RemoteMsg selfNodeId msg
  return $ state { msgStream = msgStream' }
update (Incoming msg) LoopConfig{..} state = do
  liftIO $ debugM rootLoggerName $ "received :" ++ show msg
  return $ state { received = Set.insert msg (received state) }


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


runProcess' :: LocalNode -> P.Process a -> IO a
runProcess' node process = do
  var <- newEmptyMVar
  runProcess node $ do
    res <- process
    liftIO $ putMVar var res
  readMVar var
