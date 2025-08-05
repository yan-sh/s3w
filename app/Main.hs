{-# LANGUAGE OverloadedRecordDot #-}

module Main where

import Prelude hiding (log)
import Paths_s3w (version)
import qualified System.Environment as Env
import Control.Exception
import Control.Monad
import Control.Concurrent
import GHC.Exception
import Network.Wai.Handler.Warp
import Network.Wai
import Network.Minio 
import Network.HTTP.Types
import Network.HTTP.Client.TLS
import Data.Text as T
import Data.Text.Encoding as TE
import Data.String
import Data.ByteString as B
import Data.Binary.Builder (fromByteString)
import Data.Conduit
import Data.Conduit.Combinators as CC hiding (encodeUtf8)
import Data.Conduit.List as CL
-- import Data.IORef
import Control.Monad.IO.Class
import Control.Concurrent.Async
import qualified UnliftIO.Exception as U
import qualified UnliftIO.MVar as U
import Colog.Json
import Colog.Json.Action
import Data.Aeson
import System.IO as SIO
import Data.Version (showVersion)
import Data.Time

data LogSerevity = Info | Err

data Ctx = forall a . ToJSON a => Ctx a 

asCtx :: forall a . ToJSON a => a -> Ctx
asCtx = Ctx

log :: LogSerevity -> Text -> [(Text, Ctx)] -> String -> IO ()
log s ns ctxs msg = do
  f ctx $ fromString msg
  where
    f = case s of
          Info  -> logInfo
          Err   -> logErr
    ctx = addNamespace ns
      . Prelude.foldr (\(t, Ctx a) acc -> addContext (sl t a) . acc) id ctxs
      $ mkLogger (logToHandle SIO.stderr)

main :: IO ()
main = do
  Env.getArgs >>= \case
    ["--version"] -> putStrLn (showVersion version)
    _ -> do
      s3region <- T.pack <$> obtainEnv "S3_REGION"
      s3conn <- fromString <$> obtainEnv "S3_CONN_STR"
      s3creds <- obtainS3Creds 
      conn <- join $ mkMinioConn (setRegion s3region . setCreds s3creds $ s3conn ) <$> newTlsManager
      port <- read <$> obtainEnv "S3W_PORT"
      run port $ withQueueOperationsMVar $ app conn

obtainS3Creds :: IO CredentialValue
obtainS3Creds = findFirst [fromAWSEnv] >>= \case
  Nothing -> throwIO
    $ errorCallException "Not found AWS_ACCESS_KEY_ID or AWS_SECRET_ACCESS_KEY environment variables"
  Just cv -> pure cv


obtainEnv :: String -> IO String
obtainEnv env = do
  Env.lookupEnv env >>= \case
    Nothing -> throwIO $ errorCallException $ "Not found " <> env <> " env"
    Just connStr_ -> pure connStr_


type MakeQ q = IO q
type OnTakingQ q = q -> IO () -> (ByteString -> IO ()) -> IO ()
type PutQ q = q -> ByteString -> IO ()
type CloseQ q = q -> IO ()

withQueueOperationsMVar
  ::  (forall q . QueueHandler q -> r)
  -> r
withQueueOperationsMVar cont = cont $ QueueHandler
  do newEmptyMVar
  do \m_ onClose onTake -> takeMVar m_ >>= maybe onClose onTake
  do \m_ -> putMVar m_ . Just
  do \m_ -> putMVar m_ Nothing

data QueueHandler q = QueueHandler
  { makeQ :: MakeQ q
  , onTakingQ :: OnTakingQ q
  , putQ :: PutQ q
  , closeQ :: CloseQ q
  }

app :: MinioConn -> QueueHandler q -> Application

type Logger = LogSerevity -> Text -> [(Text, Ctx)] -> String -> IO ()

mkLogCurrentTime :: Logger -> Logger
mkLogCurrentTime logger ls_ ns ctxs msg = do
  time_ <- getCurrentTime
  logger ls_ ns (ctxs <> [("time", asCtx time_)]) msg

mkLogBucketKey :: Text -> Text -> Logger -> Logger
mkLogBucketKey b k logger ls_ ns ctxs msg = logger ls_ ns ctxs_ msg
  where ctxs_ = ctxs <>
          [ ("bucket", asCtx b)
          , ("key", asCtx k)
          ]

mkLogMethod :: Text -> Logger -> Logger
mkLogMethod m logger ls_ ns ctxs msg = logger ls_ ns ctxs_ msg
  where ctxs_ = ctxs <>
          [ ("method", asCtx m)
          ]



app minioConn qh req rr
  | "GET"         <- requestMethod req
  , [bucket, key] <- pathInfo req 
  = do
  
    let log_ = mkLogBucketKey bucket key $ mkLogMethod "get" $ mkLogCurrentTime log

    log_ Info "client" [] "got request"

    q <- qh.makeQ

    gorObjectInfoMVar <- newEmptyMVar
    
    _ <- async do
      (void $ runMinioWith minioConn do
        gor <- do
          U.try (getObject bucket key defaultGetObjectOptions) >>= \case
            Left (e :: SomeException) -> U.putMVar gorObjectInfoMVar (Left e) >> U.throwIO e
            Right gor -> gor <$ U.putMVar gorObjectInfoMVar (Right $ gorObjectInfo gor)

        runConduit (gorObjectStream gor .| CC.mapM_ (liftIO . qh.putQ q ))
          ) `finally` qh.closeQ q `catch` \(e :: SomeException) ->
            log_ Err "s3" [("exception", asCtx $ show e) ] "got exception"

    takeMVar gorObjectInfoMVar >>= \case
      Left e -> do
        log_ Err "s3" [ ("exception", asCtx $ show e) ] "got exception"
        rr $ responseLBS internalServerError500 [] ""
      Right gorObjectInfo_ -> do
        let size_ = T.pack $ show $ oiSize (gorObjectInfo_)
        log_ Info "client" [ ("length", asCtx size_) ] "start streaming"
        rr $ responseStream ok200
            [ ( hContentType, "application/octet-stream")
            , ( hContentLength, encodeUtf8 size_)
            , ( "content-disposition", "attachment; filename=" <> TE.encodeUtf8 key)
            ]
            \sendChunk flush -> do
              let go = qh.onTakingQ q flush (\chunk -> sendChunk (fromByteString chunk) >> go)
               in go
     


app minioConn _ req rr
  | "PUT"         <- requestMethod req
  , [bucket, key] <- pathInfo req = do

    let log_ = mkLogBucketKey bucket key $ mkLogMethod "put" $ mkLogCurrentTime log

    log_ Info "client" [] "got request"
    try (runMinioWith minioConn do
      putObject bucket key
        (unfoldM chunksReader (getRequestBodyChunk req)) Nothing defaultPutObjectOptions
        ) >>= \case
          Left (e :: SomeException) -> do
            log_ Err "s3" [("exception", asCtx $ show e) ] "got exception"
            rr $ responseLBS internalServerError500 [] ""
          Right _ -> do 
            log_ Info "client" [] "start streaming"
            rr $ responseLBS ok200 [] ""
      where
        chunksReader f = do
          res <- liftIO f
          pure $ if B.null res then Nothing else Just (res, f)



app _ _ _ rr = rr $ responseLBS badRequest400 [] "API is not supported yet"
