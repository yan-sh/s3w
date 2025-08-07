{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}

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
import Text.Read (readMaybe)
import Data.List as L

pattern KeyBucket :: Text -> Text -> [Text]
pattern KeyBucket k b <- b : (mconcat . L.intersperse (T.pack "/") -> k)

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
      withQueueOperationsMVar (run port) (app conn)

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


-- type MakeQ q = IO q
-- type OnTakingQ q = q -> (forall a . IO a -> (ByteString -> IO a) -> IO a)
-- type PutQ q = q -> ByteString -> IO ()
-- type CloseQ q = q -> IO ()

withQueueOperationsMVar
  :: (a -> IO b)
  -> (IO QueueHandler -> a)
  -> IO b
withQueueOperationsMVar f1 f2 = do
  f1 $ f2 do
    q <- newEmptyMVar
    pure $ QueueHandler
      do (\onClose onTake -> takeMVar q >>= maybe onClose onTake)
      do putMVar q . Just
      do putMVar q Nothing

data QueueHandler = QueueHandler
  { onTakingQ :: forall a . IO a -> (ByteString -> IO a) -> IO a
  , putQ :: ByteString -> IO ()
  , closeQ :: IO ()
  }


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


app :: MinioConn -> IO QueueHandler -> Application
app minioConn mkQ req@(pathInfo -> KeyBucket key bucket) rr | "GET" <- requestMethod req= do
    let log_ = mkLogBucketKey bucket key $ mkLogMethod "get" $ mkLogCurrentTime log
    QueueHandler{..} <- mkQ
    gorObjectInfoMVar <- newEmptyMVar

    log_ Info "client" [] "got request"
    
    let chunkStreamer sendChunk flush = 
          let go_ = onTakingQ flush (\chunk -> sendChunk (fromByteString chunk) >> go_)
          in go_ 

        minioGet = do
          log_ Info "client" [] "start getting"
          void $ runMinioWith minioConn do
            gor <- do
              U.try (getObject bucket key defaultGetObjectOptions) >>= \case
                Left (e :: SomeException) -> U.putMVar gorObjectInfoMVar (Left e) >> U.throwIO e
                Right gor -> gor <$ U.putMVar gorObjectInfoMVar (Right $ gorObjectInfo gor)
            runConduit (gorObjectStream gor .| CC.mapM_ (liftIO . putQ))
          log_ Info "client" [] "getting done"
 
    void $ async do
      minioGet
        `catch` (\(e :: SomeException) -> log_ Err "s3" [("exception", asCtx $ show e) ] "got exception")
        `finally` closeQ

    takeMVar gorObjectInfoMVar >>= \case
      Left e -> do
        log_ Err "s3" [ ("exception", asCtx $ show e) ] "got exception"
        rr $ responseLBS internalServerError500 [] ""
      Right gorObjectInfo_
        | size_ <- T.pack $ show $ oiSize gorObjectInfo_ -> do
        rr $ responseStream ok200
            [ ( hContentType, "application/octet-stream")
            , ( hContentLength, encodeUtf8 size_)
            , ( "content-disposition", "attachment; filename=" <> TE.encodeUtf8 key)
            ]
            chunkStreamer


    

app minioConn mkQ req@(pathInfo -> KeyBucket key bucket) rr | "PUT" <- requestMethod req = do
  let log_ = mkLogBucketKey bucket key $ mkLogMethod "put" $ mkLogCurrentTime log
  QueueHandler{..} <- mkQ

  log_ Info "client" [] "got request"

  let minioPut = do 
        log_ Info "client" [] "start putting"
        void
          $ runMinioWith minioConn
          $ case lookup hContentLength (requestHeaders req) of
              Just (readMaybe . T.unpack . TE.decodeUtf8 -> Just length_) -> do
                putObjectStream bucket key
                  (unfoldM (liftIO . reqBodyStreamSink) ())
                  length_
                  minioConn
                  defaultPutObjectOptions
                    { pooIfNoneMatch = Just "*"
                    , pooContentDisposition = TE.decodeUtf8 <$> lookup "content-disposition" (requestHeaders req)
                    }
              _ -> do
                liftIO $ log_ Info "s3" [] "no streaming"
                putObject bucket key
                  (unfoldM (liftIO . reqBodyStreamSink) ())
                  Nothing
                  defaultPutObjectOptions

        log_ Info "client" [] "putting done"

      reqBodyStreamSource = do
        chunk <- getRequestBodyChunk req
        if B.null chunk
           then closeQ
           else putQ chunk >> reqBodyStreamSource 

      reqBodyStreamSink _ =
        onTakingQ (pure Nothing) (\bs -> pure $ Just (bs, ()))
  
  _ <- async reqBodyStreamSource

  try minioPut >>= \case
    Right _ -> do
      rr $ responseLBS ok200 [] ""
    Left (e :: SomeException) -> do
      log_ Err "s3" [("exception", asCtx $ show e) ] "got exception"
      rr $ responseLBS internalServerError500 [] ""

      -- reqBodyStreamSink _ = onTakingQ q (pure Nothing) (\bs -> pure $ Just (bs, ()))
            



app _ _ _ rr = rr $ responseLBS badRequest400 [] "API is not supported yet"
