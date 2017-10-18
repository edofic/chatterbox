{-# LANGUAGE DeriveGeneric #-}

module Chatterbox.Types where

import           Data.Binary (Binary)
import           GHC.Generics (Generic)
import           System.Random (randomR, StdGen)
import qualified Control.Distributed.Process as P
import qualified Data.Map as Map
import qualified Data.Set as Set

type Seconds = Int
type Serial = Integer
type Timestamp = Integer

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
              | Running { msgGen :: !MsgGen
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


data MsgGen = MsgGen !Serial StdGen

instance Eq MsgGen where
  MsgGen s1 _ == MsgGen s2 _ = s1 == s2

instance Show MsgGen where
  show (MsgGen s _) = "MsgGen " ++ show s ++ " <gen>"


currentSerial :: MsgGen -> Serial
currentSerial (MsgGen serial _) = serial

genMsg :: MsgGen -> (Serial, Integer)
genMsg gen = case advance gen of (serial, value, _) -> (serial, value)

advance :: MsgGen -> (Serial, Integer, MsgGen)
advance (MsgGen serial gen) = (serial, value, msgGen') where
  (value, gen') = randomR (0, maxValue) gen
  msgGen' = MsgGen (serial + 1) gen'
