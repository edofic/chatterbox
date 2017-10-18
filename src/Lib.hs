{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}

module Lib
( Config(..)
, AppState(..)
, runNode
, compact
, packPeer
, RemoteMsg(..)
, Prefix(Prefix)
, sumUpMessagesSuffix
) where

import           Control.Concurrent (threadDelay)
import           Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar)
import           Control.Distributed.Process.Node (LocalNode, initRemoteTable, runProcess, newLocalNode)
import           Control.Monad (forever, forM_)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Trans.Writer.Strict (Writer, runWriter, tell)
import           Data.Aeson (eitherDecode')
import           Data.Binary (Binary)
import           Data.Time.Clock.POSIX (getPOSIXTime)
import           GHC.Generics (Generic)
import           Network.Transport (EndPointAddress(EndPointAddress))
import           Network.Transport.TCP (createTransport, defaultTCPParameters)
import           System.Log.Logger (debugM, rootLoggerName)
import           System.Random (mkStdGen, randomRs, randomIO)
import qualified Control.Distributed.Process as P
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BS
import qualified Data.Map as Map
import qualified Data.Sequence as Seq
import qualified Data.Set as Set


type Seconds = Int

precision :: Int
precision = 10

maxValue :: Integer
maxValue = product $ replicate precision 10


data Config = Config
  { host :: String
  , port :: String
  , peersFile :: FilePath
  , sendFor :: Seconds
  , waitFor :: Seconds
  , withSeed :: Maybe Int
  , tickMs :: Int
  , verbose :: Bool
  } deriving (Eq, Show)


data LoopConfig = LoopConfig
  { selfNodeId :: !P.NodeId
  , peerList :: !(Set.Set P.NodeId)
  , sendForDelay :: !Int
  , waitForDelay :: !Int
  , randomSeed :: !Int
  , currentTimestamp :: !Timestamp
  }


data AppState = Connecting { connectedNodes :: Set.Set P.NodeId }
              | Running { msgStream :: ![(Serial, Integer)]
                        , buffer :: !(Map.Map P.NodeId (Timestamp, Integer))
                        , received :: !(Set.Set (Timestamp, Integer))
                        , latest :: !(Map.Map P.NodeId Timestamp)
                        , prefix :: !Prefix
                        , sendingTimestamp :: !Timestamp
                        , stopping :: !Bool
                        , acked :: !(Set.Set P.NodeId)
                        }
              | Quitted
              deriving (Eq, Show)

data Prefix = Prefix !Int !Integer !Timestamp deriving (Eq, Show)


type Serial = Integer
type Timestamp = Integer

data RemoteMsg = Connect P.NodeId
               | Ping P.NodeId Serial Timestamp Integer
               | Ack P.NodeId Serial
               deriving (Eq, Show, Ord, Generic)

data Msg = Incoming RemoteMsg
         | Tick
         | Stop
         | Quit
         deriving (Eq, Show, Generic)

instance Binary RemoteMsg
instance Binary Msg


data Cmd = Log String
         | Print String
         | Send P.NodeId RemoteMsg
         | TriggerStopTimer
         | TriggerQuitTimer
         | WakeUpTicker


cmd :: Cmd -> Writer (Seq.Seq Cmd) ()
cmd = tell . Seq.singleton


runNode :: Config -> IO ()
runNode config@Config {..} = do
  debugM rootLoggerName $ "Using config: " ++ show config

  node <- createTransport host port defaultTCPParameters >>= \r -> case r of
    Right transport -> newLocalNode transport initRemoteTable
    Left  err       -> error $ show err

  selfNodeId <- runProcess' node P.getSelfNode
  peerList <- loadPeers peersFile

  runProcess node $ do
    registerReceiver
    _ <- P.spawnLocal $ do
      P.getSelfPid >>= P.register "ticker"
      forever $ do
        _ <- P.expectTimeout (tickMs * 1000) :: P.Process (Maybe ())
        P.nsend "worker" Tick

    randomSeed <- case withSeed of Just seed -> return seed
                                   Nothing   -> liftIO randomIO

    let loopConfig = LoopConfig selfNodeId peerList (sendFor * 1000000) (waitFor * 500000) randomSeed
        initialState = Connecting Set.empty
    P.getSelfPid >>= P.register "worker"
    mainLoop loopConfig initialState


loadPeers :: FilePath -> IO (Set.Set P.NodeId)
loadPeers peersFile = do
  rawJson <- BS.readFile peersFile
  case eitherDecode' rawJson of
    Left err -> error $ "Cannot read " ++ peersFile ++ " : " ++ err
    Right rawPeers -> return $ Set.fromList $ map packPeer rawPeers

packPeer :: String -> P.NodeId
packPeer = P.NodeId . EndPointAddress . BSC.pack


mainLoop :: (Timestamp -> LoopConfig) -> AppState -> P.Process ()
mainLoop _ Quitted = return ()
mainLoop loopConfigF !state = do
  msg <- P.expect
  loopConfig <- loopConfigF <$> liftIO getCurrentTimestamp
  let (state', cmds) = runWriter $ update msg loopConfig state
  forM_ cmds $ runCmd loopConfig
  mainLoop loopConfigF state'

update :: Msg -> LoopConfig -> AppState -> Writer (Seq.Seq Cmd) AppState

update Tick LoopConfig{..} state@Connecting{..} = do
  cmd $ Log "connecting ..."
  forM_ peerList $ \peer -> cmd $ Send peer $ Connect selfNodeId
  return state

update (Incoming incoming) LoopConfig{..} state@Connecting{..} = do
  cmd $ Log $ "connected to "  ++ show nodeId
  let connectedNodes' = nodeId `Set.insert` connectedNodes
  if connectedNodes' == peerList
  then do
    cmd TriggerStopTimer
    let msgStream = zip [1..] $ randomRs (0, maxValue) (mkStdGen randomSeed)
        initialLatest = Map.fromList $ zip (Set.toList peerList) (repeat 0)
        prefix = Prefix 0 0 0
    return $ Running msgStream Map.empty Set.empty initialLatest prefix currentTimestamp False Set.empty -- TODO
  else return $ state { connectedNodes = connectedNodes' }
  where
    nodeId = case incoming of
      Connect sender -> sender
      Ping sender _ _ _ -> sender
      Ack sender _ -> sender

update Tick LoopConfig{..} state@Running{..}
  | stopping  = return state
  | otherwise = do
    let (msgSerial, msg) = head msgStream
    forM_ (peerList Set.\\ acked) $ \peer -> do
      cmd $ Log $ "sending to " ++ show peer
      cmd $ Send peer $ Ping selfNodeId msgSerial sendingTimestamp msg
    return state

update (Incoming msg) LoopConfig{..} state@Running{..} = do
  cmd $ Log $ "received: " ++ show msg
  case msg of
    Ping sender serial timestamp value -> do
      cmd $ Send sender $ Ack selfNodeId serial
      let buffer' = Map.insert sender (timestamp, value) buffer
          state' = state { buffer = buffer' }
      case Map.lookup sender buffer of
        Just buffered@(timestamp', _)
          | timestamp' < timestamp -> do
            cmd $ Log $ "commited " ++ show buffered
            return $ compact $ state' { received = Set.insert buffered received
                                      , latest = Map.insert sender timestamp latest
                                      }

          | otherwise -> return state'
        Nothing -> return state'

    Ack sender serial | serial == fst (head msgStream) ->
      let acked' = Set.insert sender acked
      in if acked' == peerList
         then do
           cmd WakeUpTicker
           return state { acked = Set.empty
                         , msgStream = tail msgStream
                         , sendingTimestamp = currentTimestamp
                         }
         else
           return $ state { acked = acked' }
    _ -> return state

update Stop LoopConfig{..} state@Running{..}
  | not stopping = do
    cmd $ Log "stopping"
    cmd TriggerQuitTimer
    return $ state{ stopping = True }

update Quit _ Running{ received, prefix = Prefix prefixCount prefixSum _ , stopping }
  | stopping = do
      cmd $ Log "quitting"
      cmd $ Log $ show received
      cmd $ Print $ formatResult $
        sumUpMessagesSuffix prefixCount prefixSum received
      return Quitted

update msg _ state = error $ "unexpected message: " ++ show msg ++ " in " ++ show state


-- using explicit recursion since tuples are too lazy for foldl' and foldl
-- (the library) seems like an overkill right now
sumUpMessagesSuffix :: Int -> Integer -> Set.Set (Timestamp, Integer) -> (Int, Integer)
sumUpMessagesSuffix c s entries = go c s $ Set.toList entries where
  go !count !scalar ((_, value):msgs) =
    go (count + 1) (scalar + value * (fromIntegral count + 1)) msgs
  go count scalar [] = (count, scalar)


compact :: AppState -> AppState
compact state@Running{ received, latest, prefix=(Prefix prefixCount prefixSum prefixTimestamp) }
  | prefixTimestamp' > prefixTimestamp = state { received=received', prefix=prefix' }
  where
    prefix' = Prefix prefixCount' prefixSum' prefixTimestamp
    (prefixCount', prefixSum') = sumUpMessagesSuffix prefixCount prefixSum toCompact
    (toCompact, received') = Set.partition receivedElegible received
    receivedElegible (timestamp, _) = timestamp <= prefixTimestamp'
    prefixTimestamp' = minimum (Map.elems latest)
compact state = state


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


formatResult :: (Int, Integer) -> String
formatResult (totalCount, totalSum) =
  "(" ++ show totalCount ++ ", " ++ sumStr ++ ")"
  where
  sumStr = whole ++ "." ++ decimal
  (whole, decimal) = splitAt 10 $ show totalSum


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


getCurrentTimestamp :: IO Timestamp
getCurrentTimestamp = round . (* 1000000) <$> getPOSIXTime
