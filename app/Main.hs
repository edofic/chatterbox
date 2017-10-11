module Main where

import           Options.Applicative

import Lib (Config(Config), runNode)


main :: IO ()
main = do
  config <- execParser $ info configParser mempty
  runNode config


configParser :: Parser Config
configParser = Config
  <$> strOption (long "host" <> short 'h' <> metavar "HOST" <> value "127.0.0.1")
  <*> strOption (long "port" <> short 'p' <> metavar "PORT" <> value "3000")
