-- Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedStrings #-}
module DA.Daml.LF.ScenarioServiceClient.LowLevel
  ( Options(..)
  , TimeoutSeconds
  , findServerJar
  , Handle
  , BackendError(..)
  , Error(..)
  , withScenarioService
  , ContextId
  , newCtx
  , cloneCtx
  , deleteCtx
  , gcCtxs
  , ContextUpdate(..)
  , LightValidation(..)
  , updateCtx
  , runScenario
  , SS.ScenarioResult(..)
  , encodeModule
  , ScenarioServiceException(..)
  ) where

import Conduit (runConduit, (.|))
import GHC.Generics
import Text.Read
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.DeepSeq
import Control.Exception
import Control.Monad
import Control.Monad.IO.Class
import qualified DA.Daml.LF.Proto3.EncodeV1 as EncodeV1
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Conduit as C
import Data.Conduit.Process (withCheckedProcessCleanup)
import qualified Data.Conduit.Text as C.T
import Data.Int (Int64)
import Data.List.Split (splitOn)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Vector as V
import Network.GRPC.HighLevel.Client (Client, ClientError, ClientRequest(..), ClientResult(..), GRPCMethodType(..))
import Network.GRPC.HighLevel.Generated (withGRPCClient)
import Network.GRPC.LowLevel (ClientConfig(..), Host(..), Port(..), StatusCode(..))
import qualified Proto3.Suite as Proto
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import qualified System.IO
import System.Process (proc, CreateProcess, readCreateProcessWithExitCode)

import DA.Bazel.Runfiles
import qualified DA.Daml.LF.Ast as LF
import qualified ScenarioService as SS

data Options = Options
  { optServerJar :: FilePath
  , optRequestTimeout :: TimeoutSeconds
  , optLogInfo :: String -> IO ()
  , optLogError :: String -> IO ()
  }

type TimeoutSeconds = Int

data Handle = Handle
  { hClient :: Client
  , hOptions :: Options
  }

newtype ContextId = ContextId { getContextId :: Int64 }
  deriving (NFData, Eq, Show)

-- | If true, the scenario service server only runs a subset of validations.
newtype LightValidation = LightValidation { getLightValidation :: Bool }

data ContextUpdate = ContextUpdate
  { updLoadModules :: ![(LF.ModuleName, BS.ByteString)]
  , updUnloadModules :: ![LF.ModuleName]
  , updLoadPackages :: ![(LF.PackageId, BS.ByteString)]
  , updUnloadPackages :: ![LF.PackageId]
  , updDamlLfVersion :: LF.Version
  , updLightValidation :: LightValidation
  }

encodeModule :: LF.Version -> LF.Module -> BS.ByteString
encodeModule version m = case version of
    LF.V1{} -> BSL.toStrict (Proto.toLazyByteString (EncodeV1.encodeModule version m))

data BackendError
  = BErrorClient ClientError
  | BErrorFail StatusCode
  deriving Show

data Error
  = ScenarioError SS.ScenarioError
  | BackendError BackendError
  | ExceptionError SomeException
  deriving (Generic, Show)

instance NFData Error where
    rnf = rwhnf

findServerJar :: IO FilePath
findServerJar = do
  runfilesDir <- locateRunfiles (mainWorkspace </> "compiler/scenario-service/server")
  pure (runfilesDir </> "scenario-service.jar")

-- | Return the 'CreateProcess' for running java.
-- Uses 'java' from JAVA_HOME if set, otherwise calls java via
-- /usr/bin/env. This is needed when running under "bazel run" where
-- JAVA_HOME is correctly set, but 'java' is not in PATH.
javaProc :: [String] -> IO CreateProcess
javaProc args =
  lookupEnv "JAVA_HOME" >>= return . \case
    Nothing ->
      proc "java" args
    Just javaHome ->
      let javaExe = javaHome </> "bin" </> "java"
      in proc javaExe args

data ScenarioServiceException = ScenarioServiceException String deriving Show

instance Exception ScenarioServiceException

validateJava :: Options -> IO ()
validateJava Options{..} = do
    getJavaVersion <- liftIO $ javaProc ["-version"]
    -- We could validate the Java version here but Java version strings are annoyingly
    -- inconsistent, e.g. you might get
    -- java version "11.0.2" 2019-01-15 LTS
    -- or
    -- openjdk version "1.8.0_181"
    -- so for now we only verify that "java -version" runs successfully.
    (exitCode, _stdout, stderr) <- readCreateProcessWithExitCode getJavaVersion "" `catch`
      (\(e :: IOException) -> throwIO (ScenarioServiceException ("Failed to run java: " <> show e)))
    case exitCode of
        ExitFailure _ -> throwIO (ScenarioServiceException ("Failed to start `java -version`: " <> stderr))
        ExitSuccess -> pure ()

withScenarioService :: Options -> (Handle -> IO a) -> IO a
withScenarioService opts@Options{..} f = do
  optLogInfo "Starting scenario service..."
  serverJarExists <- doesFileExist optServerJar
  unless serverJarExists $
      throwIO (ScenarioServiceException (optServerJar <> " does not exist."))
  validateJava opts
  cp <- javaProc ["-jar" , optServerJar]
  withCheckedProcessCleanup cp $ \(stdinHdl :: System.IO.Handle) stdoutSrc stderrSrc ->
          flip finally (System.IO.hClose stdinHdl) $ do
    let splitOutput = C.T.decode C.T.utf8 .| C.T.lines
    let printStderr line
            -- The last line should not be treated as an error.
            | T.strip line == "ScenarioService: stdin closed, terminating server." =
              liftIO (optLogInfo (T.unpack ("SCENARIO SERVICE STDERR: " <> line)))
            | otherwise =
              liftIO (optLogError (T.unpack ("SCENARIO SERVICE STDERR: " <> line)))
    let printStdout line = liftIO (optLogInfo (T.unpack ("SCENARIO SERVICE STDOUT: " <> line)))
    -- stick the error in the mvar so that we know we won't get an BlockedIndefinitedlyOnMvar exception
    portMVar <- newEmptyMVar
    let handleStdout = do
          mbLine <- C.await
          case mbLine of
            Nothing ->
              liftIO (putMVar portMVar (Left "Stdout of scenario service terminated before we got the PORT=<port> message"))
            Just (T.unpack -> line) ->
              case splitOn "=" line of
                ["PORT", ps] | Just p <- readMaybe ps ->
                  liftIO (putMVar portMVar (Right p)) >> C.awaitForever printStdout
                _ -> do
                  liftIO (optLogError ("Expected PORT=<port> from scenario service, but got '" <> line <> "'. Ignoring it."))
                  handleStdout
    withAsync (runConduit (stderrSrc .| splitOutput .| C.awaitForever printStderr)) $ \_ ->
        withAsync (runConduit (stdoutSrc .| splitOutput .| handleStdout)) $ \_ ->
        -- The scenario service will shut down cleanly when stdin is closed so we do this at the end of
        -- the callback. Note that on Windows, killThread will not be able to kill the conduits
        -- if they are blocked in hGetNonBlocking so it is crucial that we close stdin in the
        -- callback or withAsync will block forever.
        flip finally (System.IO.hClose stdinHdl) $ do
            System.IO.hFlush System.IO.stdout
            port <- either fail pure =<< takeMVar portMVar
            liftIO $ optLogInfo $ "Scenario service backend running on port " <> show port
            let grpcConfig = ClientConfig (Host "localhost") (Port port) [] Nothing
            withGRPCClient grpcConfig $ \client ->
                f Handle
                    { hClient = client
                    , hOptions = opts
                    }

newCtx :: Handle -> IO (Either BackendError ContextId)
newCtx Handle{..} = do
  ssClient <- SS.scenarioServiceClient hClient
  res <-
    performRequest
      (SS.scenarioServiceNewContext ssClient)
      (optRequestTimeout hOptions)
      SS.NewContextRequest
  pure (ContextId . SS.newContextResponseContextId <$> res)

cloneCtx :: Handle -> ContextId -> IO (Either BackendError ContextId)
cloneCtx Handle{..} (ContextId ctxId) = do
  ssClient <- SS.scenarioServiceClient hClient
  res <-
    performRequest
      (SS.scenarioServiceCloneContext ssClient)
      (optRequestTimeout hOptions)
      (SS.CloneContextRequest ctxId)
  pure (ContextId . SS.cloneContextResponseContextId <$> res)

deleteCtx :: Handle -> ContextId -> IO (Either BackendError ())
deleteCtx Handle{..} (ContextId ctxId) = do
  ssClient <- SS.scenarioServiceClient hClient
  res <-
    performRequest
      (SS.scenarioServiceDeleteContext ssClient)
      (optRequestTimeout hOptions)
      (SS.DeleteContextRequest ctxId)
  pure (void res)

gcCtxs :: Handle -> [ContextId] -> IO (Either BackendError ())
gcCtxs Handle{..} ctxIds = do
    ssClient <- SS.scenarioServiceClient hClient
    res <-
        performRequest
            (SS.scenarioServiceGCContexts ssClient)
            (optRequestTimeout hOptions)
            (SS.GCContextsRequest (V.fromList (map getContextId ctxIds)))
    pure (void res)

updateCtx :: Handle -> ContextId -> ContextUpdate -> IO (Either BackendError ())
updateCtx Handle{..} (ContextId ctxId) ContextUpdate{..} = do
  ssClient <- SS.scenarioServiceClient hClient
  res <-
    performRequest
      (SS.scenarioServiceUpdateContext ssClient)
      (optRequestTimeout hOptions) $
      SS.UpdateContextRequest
          ctxId
          (Just updModules)
          (Just updPackages)
          (getLightValidation updLightValidation)
  pure (void res)
  where
    updModules =
      SS.UpdateContextRequest_UpdateModules
        (V.fromList (map convModule updLoadModules))
        (V.fromList (map encodeName updUnloadModules))
    updPackages =
      SS.UpdateContextRequest_UpdatePackages
        (V.fromList (map snd updLoadPackages))
        (V.fromList (map (TL.fromStrict . LF.unPackageId) updUnloadPackages))
    encodeName = TL.fromStrict . T.intercalate "." . LF.unModuleName
    convModule :: (LF.ModuleName, BS.ByteString) -> SS.Module
    -- FixMe(#415): the proper minor version should be passed instead of "0"
    convModule (_, bytes) =
        case updDamlLfVersion of
            LF.V1 minor -> SS.Module (Just (SS.ModuleModuleDamlLf1 bytes)) (TL.pack $ LF.renderMinorVersion minor)

runScenario :: Handle -> ContextId -> LF.ValueRef -> IO (Either Error SS.ScenarioResult)
runScenario Handle{..} (ContextId ctxId) name = do
  ssClient <- SS.scenarioServiceClient hClient
  res <-
    performRequest
      (SS.scenarioServiceRunScenario ssClient)
      (optRequestTimeout hOptions)
      (SS.RunScenarioRequest ctxId (Just (toIdentifier name)))
  pure $ case res of
    Left err -> Left (BackendError err)
    Right (SS.RunScenarioResponse (Just (SS.RunScenarioResponseResponseError err))) -> Left (ScenarioError err)
    Right (SS.RunScenarioResponse (Just (SS.RunScenarioResponseResponseResult r))) -> Right r
    Right _ -> error "IMPOSSIBLE: missing payload in RunScenarioResponse"
  where
    toIdentifier :: LF.ValueRef -> SS.Identifier
    toIdentifier (LF.Qualified pkgId modName defn) =
      let ssPkgId = SS.PackageIdentifier $ Just $ case pkgId of
            LF.PRSelf     -> SS.PackageIdentifierSumSelf SS.Empty
            LF.PRImport x -> SS.PackageIdentifierSumPackageId (TL.fromStrict $ LF.unPackageId x)
      in
        SS.Identifier
          (Just ssPkgId)
          (TL.fromStrict $ T.intercalate "." (LF.unModuleName modName) <> ":" <> LF.unExprValName defn)

performRequest
  :: (ClientRequest 'Normal payload response -> IO (ClientResult 'Normal response))
  -> TimeoutSeconds
  -> payload
  -> IO (Either BackendError response)
performRequest method timeoutSeconds payload = do
  method (ClientNormalRequest payload timeoutSeconds mempty) >>= \case
    ClientNormalResponse resp _ _ StatusOk _ -> return (Right resp)
    ClientNormalResponse _ _ _ status _ -> return (Left $ BErrorFail status)
    ClientErrorResponse err -> return (Left $ BErrorClient err)
