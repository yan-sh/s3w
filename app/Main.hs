{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ImpredicativeTypes #-}

module Main where

import Prelude hiding (log)
import Paths_s3w (version)
import qualified System.Environment as Env
import Control.Exception
import Control.Monad
import Control.Concurrent
import System.Timeout
import qualified UnliftIO.Timeout as U
import GHC.Exception
import Network.Wai.Handler.Warp
import Network.Wai
import Network.Minio
import Network.HTTP.Types
import Network.HTTP.Client.TLS
import Network.HTTP.Client (newManager, managerConnCount)
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
import Data.Functor ((<&>))
import Data.Function ((&), fix)
import Data.Maybe (isJust)
import Control.Concurrent.STM
import GHC.IO.Unsafe (unsafePerformIO)
import qualified Network.URI.Encode as URI.Encode


data S3WErr = S3WErrCL

pattern KeyBucket :: Text -> Text -> [Text]
pattern KeyBucket k b <- (URI.Encode.decodeText -> b) : (URI.Encode.decodeText . mconcat . L.intersperse (T.pack "/") -> k)


data LogSerevity = Debug | Info | Err 
  deriving (Eq, Ord, Read)

minimalLogSeverity :: TVar LogSerevity
minimalLogSeverity = unsafePerformIO $ newTVarIO Info

data Ctx = forall a . ToJSON a => Ctx a 

data MinioResult a = 
    MinioError MinioErr
  | MinioException SomeException
  | MinioSuccess a

pass :: Applicative f => f ()
pass = pure ()

consumeMinioResult
  :: Logger
  -> IO b
  -> IO b
  -> (a -> IO b)
  -> MinioResult a
  -> IO b
consumeMinioResult log_ onExcp onErr onSucc = \case
  MinioException e -> do
    log_ Err "s3" [("exception", asCtx $ show e) ] "got exception"
    onExcp
  MinioError me ->  do
    log_ Err "s3" [("error", asCtx $ show me) ] "got minio error"
    onErr
  MinioSuccess x -> onSucc x 
  


asCtx :: forall a . ToJSON a => a -> Ctx
asCtx = Ctx



log :: LogSerevity -> Text -> [(Text, Ctx)] -> String -> IO ()
log s ns ctxs msg = do
  f ctx $ fromString msg
  where
    withCheckLogSerevity f_ = do
      min_ <- readTVarIO minimalLogSeverity
      if s < min_
         then pass
         else f_

    f ctx_ msg_ = 
      case s of
        Info  -> withCheckLogSerevity $ logInfo ctx_ msg_
        Err   -> withCheckLogSerevity $ logErr ctx_ msg_
        Debug -> withCheckLogSerevity $ logDebug ctx_ msg_
    ctx = addNamespace ns
      . Prelude.foldr (\(t, Ctx a) acc -> addContext (sl t a) . acc) id ctxs
      $ mkLogger (logToHandle SIO.stderr)



main :: IO ()
main = do
  Env.getArgs >>= \case
    ["--version"] -> putStrLn (showVersion version)
    _ -> do
      getObjectTimeout <- maybe 30_000_000 ((* 1_000_000) . read) <$> Env.lookupEnv "S3W_GET_TIMEOUT_SEC"
      queueTimeout <- maybe 30_000_000 ((* 1_000_000) . read) <$> Env.lookupEnv "S3W_QUEUE_TIMEOUT_SEC"
      tracker <- mkConnTracker
      minioRunner <- mkMinioAppRunner tracker
      port <- read <$> obtainEnv "S3W_PORT"
      
      (Env.lookupEnv "S3W_MIN_LOG" <&> join . fmap readMaybe)
        >>= maybe pass (atomically . writeTVar minimalLogSeverity)

      void $ forkIO $ backgroundConnLogger tracker (mkLogCurrentTime log)

      withQueueOperationsTBQueue queueTimeout
        ((mkLogCurrentTime $ log) Debug "queue" [])
        (run port)
        (app getObjectTimeout minioRunner)

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

withQueueOperationsTBQueue
  :: Int
  -> (String -> IO ())
  -> (a -> IO b)
  -> (IO QueueHandler -> a)
  -> IO b
withQueueOperationsTBQueue queueTimeout log_ f1 f2 = do
  f1 $ f2 do
    q <- newTBQueueIO 256
    active <- newTVarIO True
    pure $ QueueHandler
      { onTakingQ = \onClose onTake -> do
          result <- timeout queueTimeout (atomically $ readTBQueue q)
          case result of
            Nothing -> do
              r <- onClose
              r <$ log_ "on timeout"
            Just mchunk -> case mchunk of
              Nothing -> do
                r <- onClose
                r <$ log_ "on close"
              Just x -> do
                r <- onTake x
                r <$ log_ "on take"
      , putQ = \x -> atomically $ do
          a <- readTVar active
          when a $ writeTBQueue q (Just x)
      , closeQ = atomically $ do
          writeTVar active False
          writeTBQueue q Nothing
      , stopQ = atomically $ writeTVar active False
      }

data QueueHandler = QueueHandler
  { onTakingQ :: forall a . IO a -> (ByteString -> IO a) -> IO a
  , putQ :: ByteString -> IO ()
  , closeQ :: IO ()
  , stopQ :: IO ()
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


data ConnTracker = ConnTracker
  { ctActive :: TVar Int
  , ctMax    :: Int
  }

mkConnTracker :: IO ConnTracker
mkConnTracker = ConnTracker <$> newTVarIO 0 <*> pure 50

trackConnection :: ConnTracker -> IO a -> IO a
trackConnection tracker action = do
  atomically $ modifyTVar' (ctActive tracker) (+1)
  action `finally` atomically (modifyTVar' (ctActive tracker) (subtract 1))

getActiveConns :: ConnTracker -> IO Int
getActiveConns = readTVarIO . ctActive

backgroundConnLogger :: ConnTracker -> Logger -> IO ()
backgroundConnLogger tracker logger = forever $ do
  threadDelay 5_000_000
  active <- getActiveConns tracker
  logger Debug "pool" [("active", asCtx active), ("max", asCtx $ ctMax tracker)] "connection pool stats"

data MinioHandler = MinioHandler (forall a . (MinioConn -> Minio a) -> IO (MinioResult a)) 

mkMinioAppRunner :: ConnTracker -> IO MinioHandler
mkMinioAppRunner tracker = do
  s3region <- T.pack <$> obtainEnv "S3_REGION"
  s3conn <- fromString <$> obtainEnv "S3_CONN_STR"
  s3creds <- obtainS3Creds 
  mgr <- newManager tlsManagerSettings { managerConnCount = ctMax tracker }
  conn <- mkMinioConn (setRegion s3region . setCreds s3creds $ s3conn) mgr
  pure $ MinioHandler \f -> trackConnection tracker do
    try (runMinioWith conn (f conn)) <&> \case
      Left e          -> MinioException e
      Right (Left me) -> MinioError me
      Right (Right s) -> MinioSuccess s

mkPutObjectOptions :: [Header] -> PutObjectOptions
mkPutObjectOptions = L.foldr f defaultPutObjectOptions
  where
    f (h,v) acc
      | h == "if-none-match" = acc { pooIfNoneMatch = Just "*" }
      | h == "content-disposition" = acc { pooContentDisposition = Just $ TE.decodeUtf8 v}
      | otherwise = acc

app :: Int -> MinioHandler -> IO QueueHandler -> Application
app getObjectTimeout (MinioHandler runMinioApp) mkQ req@(pathInfo -> KeyBucket key bucket) rr | "GET" <- requestMethod req= do
    let log_ = mkLogBucketKey bucket key $ mkLogMethod "get" $ mkLogCurrentTime log
    QueueHandler{..} <- mkQ
    gorObjectInfoMVar <- newEmptyMVar

    log_ Info "client" [] "got request"
    
    let minioGet = do
      
          liftIO $ log_ Debug "client.minioGet" [] "start getting getObjectResult"

          gor <- do
            U.try (U.timeout getObjectTimeout $ getObject bucket key defaultGetObjectOptions) >>= \case
              Left (e :: SomeException) -> do
                U.putMVar gorObjectInfoMVar $ Left e
                U.throwIO e
              Right Nothing -> do
                let e :: SomeException = toException $ userError "getObject timeout"
                U.putMVar gorObjectInfoMVar $ Left e
                U.throwIO e
              Right (Just gor) -> do
                U.putMVar gorObjectInfoMVar $ Right $ gorObjectInfo gor
                pure gor 
          
          liftIO $ log_ Debug "client.minioGet" [] "getting getObjectResult done"

          runConduit $ gorObjectStream gor .| CC.mapM_ (liftIO . putQ)
 
    asyncGet <- async do

      log_ Info "client" [] "start getting"

      runMinioApp (const minioGet) >>= consumeMinioResult log_ pass pass (const pass)
        
      closeQ

      log_ Info "client" [] "getting done"

    takeMVar gorObjectInfoMVar >>= \case
      Left _e -> do
        closeQ
        cancel asyncGet
        rr $ responseLBS internalServerError500 [] ""
      Right gorObjectInfo_
        | size_ <- T.pack $ show $ oiSize gorObjectInfo_ -> do
        let chunkStreamer sendChunk flush = do
              _ <- fix \f -> onTakingQ flush \chunk -> sendChunk (fromByteString chunk) >> f
              cancel asyncGet
        rr $ responseStream ok200
            [ ( hContentType, "application/octet-stream")
            , ( hContentLength, encodeUtf8 size_)
            , ( "content-disposition", "attachment; filename=" <> TE.encodeUtf8 key)
            ]
            chunkStreamer


   
app _ (MinioHandler runMinioApp) mkQ req@(pathInfo -> KeyBucket key bucket) rr | "PUT" <- requestMethod req = do
  let log_ = mkLogBucketKey bucket key $ mkLogMethod "put" $ mkLogCurrentTime log
  QueueHandler{..} <- mkQ

  log_ Info "client" [] "got request"

  let minioPut minioConn = withContentLength \length_ -> 
        if uploadStreamly
           then putObjectStream bucket key streamer length_ minioConn opts
           else putObject bucket key streamer Nothing opts
        where
          uploadStreamly = isJust $ lookup "s3w-stream" $ requestHeaders req
          streamer = unfoldM (liftIO . const (onTakingQ (pure Nothing) \bs -> pure $ Just (bs, ()))) ()
          opts = mkPutObjectOptions $ requestHeaders req
          withContentLength f =
            case lookup hContentLength (requestHeaders req) of
              Just (readMaybe . T.unpack . TE.decodeUtf8 -> Just length_) -> Right <$> f length_
              _ -> pure $ Left S3WErrCL
 
  asyncPut <- async $ fix \f -> do
    chunk <- getRequestBodyChunk req
    if B.null chunk
       then closeQ
       else putQ chunk >> f

  log_ Info "client" [] "start putting"

  minioResult <- runMinioApp minioPut
  
  log_ Info "client" [] "putting done"

  minioResult & consumeMinioResult log_
    do stopQ >> cancel asyncPut >> rr (responseLBS internalServerError500 [] "")
    do stopQ >> cancel asyncPut >> rr (responseLBS internalServerError500 [] "")
    \case
      (Left S3WErrCL) -> stopQ >> cancel asyncPut >> rr (responseLBS status400 [] "\"Content-Length\" not found")
      (Right _) -> rr $ responseLBS ok200 [] ""
      

    
app _ _ _ _ rr = rr $ responseLBS badRequest400 [] "API is not supported yet"
