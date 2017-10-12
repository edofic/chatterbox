module Main where

import           Options.Applicative
import           System.IO (stderr)
import           System.Log.Formatter (simpleLogFormatter)
import           System.Log.Handler (setFormatter)
import           System.Log.Handler.Simple (streamHandler)
import qualified System.Log.Logger as Logger

import Lib


main :: IO ()
main = do
  logStreamHandler <- streamHandler stderr Logger.DEBUG
  let logStreamHandler' = setFormatter logStreamHandler $
                            simpleLogFormatter "[$time $loggername $prio] $msg"
  Logger.updateGlobalLogger Logger.rootLoggerName $
    Logger.setLevel Logger.DEBUG . Logger.setHandlers [logStreamHandler']

  config <- execParser $ info configParser mempty
  runNode config


configParser :: Parser Config
configParser = Config
  <$> strOption (long "host" <> short 'h' <> metavar "HOST" <> value "127.0.0.1")
  <*> strOption (long "port" <> short 'p' <> metavar "PORT" <> value "3000")
  <*> configPeersParser

configPeersParser :: Parser ConfigPeers
configPeersParser = useAuto <|> useFile where
  useAuto = flag' ConfigPeersAuto (long "discover-peers")
  useFile = ConfigPeersFile <$> strOption (long "peer-config-file" <> value "peers.json")
