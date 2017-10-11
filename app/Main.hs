module Main where

import           Options.Applicative

import Lib


main :: IO ()
main = do
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
