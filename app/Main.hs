module Main where

import           Options.Applicative
import           System.IO (stderr)
import           System.Log.Formatter (simpleLogFormatter)
import           System.Log.Handler (setFormatter)
import           System.Log.Handler.Simple (streamHandler)
import qualified System.Log.Logger as Logger

import Chatterbox


main :: IO ()
main = do
  config <- execParser $ info configParser mempty
  let logLevel = if verbose config then Logger.DEBUG else Logger.ERROR

  logStreamHandler <- streamHandler stderr logLevel
  let logStreamHandler' = setFormatter logStreamHandler $
                            simpleLogFormatter "[$time $loggername $prio] $msg"
  Logger.updateGlobalLogger Logger.rootLoggerName $
    Logger.setLevel Logger.DEBUG . Logger.setHandlers [logStreamHandler']

  runNode config


configParser :: Parser Config
configParser = Config
  <$> strOption (long "host" <> short 'h' <> metavar "HOST" <> value "127.0.0.1")
  <*> strOption (long "port" <> short 'p' <> metavar "PORT" <> value "3000")
  <*> strOption (long "peer-config-file" <> value "peers.json")
  <*> option auto (long "send-for" <> metavar "l" <> value 3)
  <*> option auto (long "wait-for" <> metavar "k" <> value 1)
  <*> ((Just <$> option auto (long "with-seed")) <|> pure Nothing)
  <*> option auto (long "tick-duration" <> metavar "ms" <> value 100)
  <*> flag False True (long "verbose" <> short 'v')
