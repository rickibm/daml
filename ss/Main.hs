{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

--import Control.Concurrent.Extra
import qualified DA.Service.Daml.Compiler.Impl.Scenario as SS
--import qualified DA.Service.Logger.Impl.Pure as Logger
import qualified DA.Service.Logger.Impl.IO as Logger
--import qualified Data.Text.IO as T

main :: IO ()
main = do
    putStrLn "Starting test"
--    lock <- newLock
--    let logger = Logger.makeOneHandle $ withLock lock . T.putStrLn
--    SS.withScenarioService Logger.makeNopHandle $ \_scenarioService -> do
    logger <- Logger.newStdoutLogger "XXX"
    SS.withScenarioService logger $ \_scenarioService -> do
      putStrLn $ "Running scenario service"
    putStrLn "Test done"
