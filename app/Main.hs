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
  <*> strOption (long "peer-config-file" <> value "peers.json")
  <*> option auto (long "send-for" <> metavar "l" <> value 10)
  <*> option auto (long "wait-for" <> metavar "k" <> value 3)
  <*> ((Just <$> option auto (long "with-seed")) <|> pure Nothing)
