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


type Seconds = Int


data Config = Config
  { host :: String
  , port :: String
  , peersFile :: FilePath
  , sendFor :: Seconds
  , waitFor :: Seconds
  } deriving (Eq, Show)


data LoopConfig = LoopConfig
  { selfNodeId :: P.NodeId
  , peerList :: Set.Set P.NodeId
  , sendForDelay :: Int
  , waitForDelay :: Int
  }


data AppState = Connecting { connectedNodes :: Set.Set P.NodeId }
              | Running { msgStream :: [Integer]
                        , received :: Set.Set RemoteMsg
                        }
              | Stopped { received :: Set.Set RemoteMsg }
              | Quitted
              deriving (Eq, Show)


data RemoteMsg = Connect P.NodeId
               | Ping P.NodeId Integer
               deriving (Eq, Show, Ord, Generic)

data Msg = Incoming RemoteMsg
         | Tick
         | Stop
         | Quit
         deriving (Eq, Show, Generic)


instance Binary RemoteMsg
instance Binary Msg


runNode :: Config -> IO ()
runNode config@(Config {..}) = do
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

    let loopConfig = LoopConfig selfNodeId peerList (sendFor * 1000000) (waitFor * 1000000)
        initialState = Connecting Set.empty
    P.getSelfPid >>= P.register "worker"
    mainLoop loopConfig initialState


loadPeers :: FilePath -> P.NodeId -> IO (Set.Set P.NodeId)
loadPeers peersFile selfNodeId = do
  rawJson <- BS.readFile peersFile
  case eitherDecode' rawJson of
    Left err -> error $ "Cannot read " ++ peersFile ++ " : " ++ err
    Right rawPeers -> return $ Set.fromList $ filter (selfNodeId /=) $ map packPeer rawPeers
  where
    packPeer = P.NodeId . EndPointAddress . BSC.pack


mainLoop :: LoopConfig -> AppState -> P.Process ()
mainLoop _ Quitted = return ()
mainLoop loopConfig state = do
  msg <- P.expect
  state' <- update msg loopConfig state
  mainLoop loopConfig state'


update :: Msg -> LoopConfig -> AppState -> P.Process AppState

update Tick LoopConfig{..} state@Connecting{..} = do
  liftIO $ debugM rootLoggerName $ "connecting ... "
  forM_ peerList $ \peer ->
    P.nsendRemote peer "listener" $ Connect selfNodeId
  return state

update (Incoming incoming) LoopConfig{..} state@Connecting{..} = do
  liftIO $ debugM rootLoggerName $ "connected to "  ++ show nodeId
  let connectedNodes' = nodeId `Set.insert` connectedNodes
  if connectedNodes' == Set.delete selfNodeId peerList
  then do
    _ <- P.spawnLocal $ do
      liftIO $ debugM rootLoggerName "sleeping"
      liftIO $ threadDelay sendForDelay
      liftIO $ debugM rootLoggerName "woke up"
      P.nsend "worker" Stop
    return $ Running [1..] Set.empty
  else return $ state { connectedNodes = connectedNodes' }
  where
    nodeId = case incoming of
      Connect sender -> sender
      Ping sender _ -> sender

update Tick LoopConfig{..} state@Running{..} = do
  let msg : msgStream' = msgStream
  forM_ peerList $ \peer -> do
    liftIO $ debugM rootLoggerName $ "sending to " ++ show peer
    P.nsendRemote peer "listener" $ Ping selfNodeId msg
  return $ state { msgStream = msgStream' }

update (Incoming msg) LoopConfig{..} state@Running{} = do
  liftIO $ debugM rootLoggerName $ "received: " ++ show msg
  return $ state { received = Set.insert msg (received state) }

update Stop LoopConfig{..} Running{..} = do
  liftIO $ debugM rootLoggerName $ "stopping"
  _ <- P.spawnLocal $ do
    liftIO $ threadDelay waitForDelay
    P.nsend "worker" Quit
  return $ Stopped received

update Tick _ state@Stopped{} = return state

update Quit _ Stopped{..} = do
  liftIO $ do
    debugM rootLoggerName "quitting"
    debugM rootLoggerName $ show received
  return Quitted

update msg _ state = error $ "unexpected message: " ++ show msg ++ " in " ++ show state


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
