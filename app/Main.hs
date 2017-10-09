module Main where

import           System.Environment (getArgs)

import Lib (runNode)

main :: IO ()
main = do
  [host, port] <- getArgs
  runNode host port
