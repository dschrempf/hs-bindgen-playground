{-# LANGUAGE OverloadedStrings #-}

-- | hs-bindgen playground: a scotty server that shells out to the Nix-built
-- @hs-bindgen-cli@ inside a bubblewrap sandbox and returns generated bindings.
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM
import Control.Exception (IOException, finally)
import qualified Control.Exception as E
import Control.Monad (when)
import Data.Aeson
  (FromJSON (..), Value, object, withObject, (.!=), (.:), (.:?), (.=))
import qualified Data.ByteString as BS
import Data.Char (isAlphaNum, isSpace, isUpper)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.IO as TIO
import Network.HTTP.Types (status403, status413, status503)
import Network.Wai (pathInfo)
import System.Directory
  (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (getEnv, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeExtension, (</>))
import System.IO (Handle, hClose, hIsTerminalDevice, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.IO (closeFd, dup, fdToHandle)
import System.Posix.Terminal (openPseudoTerminal)
import System.Process
  ( CreateProcess (..)
  , StdStream (..)
  , createProcess
  , proc
  , waitForProcess
  )
import Web.Scotty

-- | Runtime configuration, all from the environment (see 'loadConfig').
data Config = Config
  { cfgPort :: Int
  , cfgStaticDir :: FilePath
  , cfgExamplesDir :: FilePath
  , cfgCli :: String
  , cfgMaxConcurrent :: Int
  , cfgMaxInputBytes :: Int
  , cfgTimeoutSecs :: Int
  , cfgMemBytes :: Integer  -- ^ prlimit --as (address space)
  , cfgVerbosity :: Int
  , cfgReadOnly :: Bool
  , cfgReadOnlyMsg :: Text
  }

-- | A curated example header shown in the UI dropdown.
data Example = Example
  { exName :: Text
  , exBody :: Text
  }

-- | A parsed generation request from the frontend.
data GenReq = GenReq
  { reqSource :: Text
  , reqStd :: Text
  , reqSafe :: Bool
  , reqModule :: Text
  , reqVerbosity :: Maybe Int  -- ^ 0–4; 'Nothing' falls back to 'cfgVerbosity'.
  , reqMacroWarnings :: Bool
  , reqExtraOpts :: Text  -- ^ free-form extra @preprocess@ options (quote-aware).
  }

instance FromJSON GenReq where
  parseJSON = withObject "GenReq" $ \o ->
    GenReq
      <$> o .: "source"
      <*> o .:? "std" .!= "c11"
      <*> o .:? "safe" .!= True
      <*> o .:? "module" .!= "Demo"
      <*> o .:? "verbosity"
      <*> o .:? "macroWarnings" .!= True
      <*> o .:? "options" .!= ""

-- | Result of a successful (or failed-but-ran) generation.
data GenResult = GenResult
  { resOk :: Bool
  , resBindings :: Text
  , resCommand :: Text
  , resDiagnostics :: Text
  , resExitCode :: Int
  }

-- | A bounded concurrency gate: at most N requests generate at once.
newtype Gate = Gate (TVar Int)

newGate :: Int -> IO Gate
newGate n = Gate <$> newTVarIO n

-- | Run the action if a slot is free, releasing it afterwards; 'Nothing' when full.
withGate :: Gate -> IO a -> IO (Maybe a)
withGate (Gate tv) act = do
  acquired <- atomically $ do
    n <- readTVar tv
    if n > 0 then writeTVar tv (n - 1) >> pure True else pure False
  if acquired
    then Just <$> (act `finally` atomically (modifyTVar' tv (+ 1)))
    else pure Nothing

main :: IO ()
main = do
  cfg <- loadConfig
  gate <- newGate (cfgMaxConcurrent cfg)
  examples <- loadExamples (cfgExamplesDir cfg)
  -- Only the friendly URL when interactive; under systemd it'd go to the journal
  -- and "localhost" is wrong there (caddy serves the real domain on 80/443).
  interactive <- hIsTerminalDevice stdout
  when interactive $
    putStrLn $ "hs-bindgen playground: http://localhost:" <> show (cfgPort cfg) <> "/"
  scotty (cfgPort cfg) $ do
    get "/" $ do
      setHeader "Content-Type" "text/html; charset=utf-8"
      file (cfgStaticDir cfg </> "index.html")

    staticRoute (cfgStaticDir cfg)

    get "/api/config" $
      json $
        object
          [ "readOnly" .= cfgReadOnly cfg
          , "message" .= cfgReadOnlyMsg cfg
          ]

    get "/api/examples" $
      json [object ["name" .= exName e, "body" .= exBody e] | e <- examples]

    post "/api/generate" $ handleGenerate cfg gate

-- | The @POST \/api\/generate@ handler: validate, gate, run, respond.
handleGenerate :: Config -> Gate -> ActionM ()
handleGenerate cfg gate
  | cfgReadOnly cfg = do
      status status503
      json $ errObj (cfgReadOnlyMsg cfg)
  | otherwise = do
      req <- jsonData
      let srcBytes = BS.length (TE.encodeUtf8 (reqSource req))
      if srcBytes > cfgMaxInputBytes cfg
        then do
          status status413
          json . errObj $
            "Input too large ("
              <> tshow srcBytes
              <> " bytes; limit "
              <> tshow (cfgMaxInputBytes cfg)
              <> ")."
        else case validate req of
          Left msg -> do
            status status403
            json (errObj msg)
          Right req' -> do
            mres <- liftIO $ withGate gate (runGenerate cfg req')
            case mres of
              Nothing -> do
                status status503
                json (errObj "Server busy — please try again in a moment.")
              Just res -> json (resultObj res)

-- | Validate module name and C standard; normalise the request.
validate :: GenReq -> Either Text GenReq
validate req
  | not (validModule (reqModule req)) =
      Left "Module name must start with an uppercase letter and contain only letters, digits, or underscores."
  | reqStd req `notElem` allowedStds =
      Left $ "Unsupported C standard: " <> reqStd req <> "."
  | not (validVerbosity (reqVerbosity req)) =
      Left "Verbosity must be between 0 and 4."
  | T.length (reqExtraOpts req) > maxOptionsLen =
      Left $ "Additional options too long (limit " <> tshow maxOptionsLen <> " chars)."
  | otherwise = Right req
  where
    validModule m =
      not (T.null m)
        && isUpper (T.head m)
        && T.all (\c -> isAlphaNum c || c == '_') m
    validVerbosity Nothing = True
    validVerbosity (Just v) = v >= 0 && v <= 4

allowedStds :: [Text]
allowedStds = ["c89", "c99", "c11", "c17", "c23"]

-- | Run the CLI in the sandbox against the request's source, in a fresh temp dir.
runGenerate :: Config -> GenReq -> IO GenResult
runGenerate cfg req =
  withSystemTempDirectory "playground" $ \tmp -> do
    let work = tmp </> "work"
        outDir = work </> "out"
        outFile = outDir </> T.unpack (reqModule req) <> ".hs"
    createDirectoryIfMissing True outDir
    TIO.writeFile (work </> "input.h") (reqSource req)
    ownPath <- getEnv "PATH"
    let sandboxArgs = buildArgv cfg req work ownPath
    -- Run on a pseudo-terminal so the CLI thinks it is interactive and emits
    -- ANSI-coloured diagnostics (the frontend renders the escapes). Diagnostics
    -- go to stderr, which the PTY merges with (empty) stdout.
    (ec, out) <- runOnPty "timeout" sandboxArgs
    haveOut <- doesFileExist outFile
    bindings <- if haveOut then TIO.readFile outFile else pure ""
    let ran = ec == ExitSuccess && haveOut
        code = case ec of ExitSuccess -> 0; ExitFailure n -> n
        diag = trimLines maxLineLen (annotateTimeout code (stripCR out))
    pure
      GenResult
        { resOk = ran
        , resBindings = truncateText maxBindings bindings
        , resCommand = displayCommand cfg req
        , resDiagnostics = truncateText maxDiagnostics diag
        , resExitCode = code
        }
  where
    -- timeout kills with SIGKILL → exit 128+9.
    annotateTimeout 137 d =
      d <> "\n[playground] Killed: exceeded the "
        <> tshow (cfgTimeoutSecs cfg)
        <> "s time limit."
    annotateTimeout _ d = d

-- | Arguments to @timeout@, chaining @timeout → prlimit → bwrap → hs-bindgen-cli@.
buildArgv :: Config -> GenReq -> FilePath -> String -> [String]
buildArgv cfg req work ownPath =
  ["--signal=KILL", show (cfgTimeoutSecs cfg) <> "s"]
    ++ [ "prlimit"
       , "--as=" <> show (cfgMemBytes cfg)
       , "--cpu=" <> show (cfgTimeoutSecs cfg)
       , "--fsize=" <> show maxFileSize
       , "--nofile=256"
       , "--"
       ]
    ++ ["bwrap"]
    ++ bwrapArgs
    ++ ["--"]
    ++ [cfgCli cfg]
    ++ cliArgs cfg req
  where
    bwrapArgs =
      [ "--unshare-all"
      , "--die-with-parent"
      , "--new-session"
      , "--clearenv"
      , "--setenv", "PATH", ownPath
      , "--setenv", "TMPDIR", "/tmp"
      , "--setenv", "HOME", "/work"
      , "--setenv", "TERM", "xterm-256color"  -- enable ANSI-coloured diagnostics
      , "--ro-bind", "/nix/store", "/nix/store"
      , "--proc", "/proc"
      , "--dev", "/dev"
      , "--tmpfs", "/tmp"
      , "--bind", work, "/work"
      , "--chdir", "/work"
      ]

-- | Run @cmd args@ with its std streams on a fresh pseudo-terminal, returning
-- the exit code and everything written to it. A PTY makes the child (and the
-- sandboxed CLI at the end of the chain) see a terminal on stderr, so it emits
-- ANSI colours. Stdout and stderr both land on the slave; a reader thread
-- drains the master concurrently to avoid the tiny PTY buffer deadlocking.
runOnPty :: String -> [String] -> IO (ExitCode, Text)
runOnPty cmd args = do
  (master, slave) <- openPseudoTerminal
  -- The child needs the slave on fds 1 and 2; give each a private dup so
  -- 'System.Process' can close them independently after the fork. Once the
  -- parent holds no slave fd, the master reads EOF/EIO when the child exits.
  slaveOut <- dup slave
  slaveErr <- dup slave
  closeFd slave
  masterH <- fdToHandle master
  hOut <- fdToHandle slaveOut
  hErr <- fdToHandle slaveErr
  outVar <- newEmptyMVar
  _ <- forkIO (drainHandle masterH >>= putMVar outVar)
  (_, _, _, ph) <-
    createProcess
      (proc cmd args)
        { std_in = NoStream
        , std_out = UseHandle hOut
        , std_err = UseHandle hErr
        , close_fds = True
        }
  ec <- waitForProcess ph
  out <- takeMVar outVar
  pure (ec, out)

-- | Read a handle to EOF, treating the PTY master's EIO-on-close as end of
-- input, and decode leniently as UTF-8. Closes the handle when done.
drainHandle :: Handle -> IO Text
drainHandle h = (TE.decodeUtf8With lenientDecode . BS.concat <$> go []) `finally` hClose h
  where
    go acc = do
      chunk <- (Just <$> BS.hGetSome h 65536) `E.catch` \(_ :: IOException) -> pure Nothing
      case chunk of
        Just c | not (BS.null c) -> go (c : acc)
        _ -> pure (reverse acc)

-- | Effective verbosity: request wins, else the configured default.
effVerbosity :: Config -> GenReq -> Int
effVerbosity cfg req = fromMaybe (cfgVerbosity cfg) (reqVerbosity req)

-- | Split a free-form option string into argv, honouring single/double quotes
-- (which group and are stripped). No shell involved — args go straight to
-- 'createProcess' as an argv list — so there is nothing to escape and no injection.
splitArgs :: Text -> [String]
splitArgs = go . T.unpack
  where
    go s = case dropWhile isSpace s of
      "" -> []
      s' -> let (tok, rest) = lexTok "" s' in tok : go rest
    lexTok acc [] = (acc, [])
    lexTok acc (c : cs)
      | isSpace c = (acc, cs)
      | c == '"' || c == '\'' =
          let (q, rest) = break (== c) cs in lexTok (acc ++ q) (drop 1 rest)
      | otherwise = lexTok (acc ++ [c]) cs

-- | The CLI arguments (also mirrored by 'displayCommand', minus paths).
cliArgs :: Config -> GenReq -> [String]
cliArgs cfg req =
  ["-v", show (effVerbosity cfg req)]
    ++ ["--log-enable-macro-warnings" | reqMacroWarnings req]
    ++
  [ "preprocess"
  , "--single-file"
  , if reqSafe req then "--safe" else "--unsafe", ""
  , "--unique-id", "playground.hs-bindgen"
  , "--module", T.unpack (reqModule req)
  , "--hs-output-dir", "/work/out"
  , "--create-output-dirs"
  , "--overwrite-files"
  , "--clang-option=-std=" <> T.unpack (reqStd req)
  ]
    ++ splitArgs (reqExtraOpts req)
    ++ ["-I", "/work", "input.h"]

-- | A human-readable, copy-pasteable version of the CLI command for the UI.
-- Paths are shown relative (@out@, @.@) rather than the sandbox @\/work@ ones.
displayCommand :: Config -> GenReq -> Text
displayCommand cfg req =
  T.intercalate " \\\n  " $
    map T.pack
      [ "hs-bindgen-cli -v " <> show (effVerbosity cfg req)
          <> (if reqMacroWarnings req then " --log-enable-macro-warnings" else "")
          <> " preprocess"
      , "--single-file " <> (if reqSafe req then "--safe" else "--unsafe") <> " ''"
      , "--unique-id playground.hs-bindgen"
      , "--module " <> T.unpack (reqModule req)
      , "--hs-output-dir out --create-output-dirs --overwrite-files"
      , "--clang-option=-std=" <> T.unpack (reqStd req)
      ]
    ++ [opts | let opts = T.strip (reqExtraOpts req), not (T.null opts)]
    ++ ["-I . input.h"]

-- Serving static assets -----------------------------------------------------

-- | Serve @\/static\/**@ from @dir@, rejecting path traversal.
staticRoute :: FilePath -> ScottyM ()
staticRoute dir = get (function matcher) $ do
  rel <- captureParam "rel"
  setHeader "Content-Type" (contentTypeFor (T.unpack rel))
  file (dir </> T.unpack rel)
  where
    matcher r = case pathInfo r of
      ("static" : rest)
        | not (null rest) && all safeSeg rest ->
            Just [("rel", T.intercalate "/" rest)]
      _ -> Nothing
    safeSeg s = not (T.null s) && s /= ".." && not (T.any (== '/') s)

contentTypeFor :: FilePath -> TL.Text
contentTypeFor p = case takeExtension p of
  ".html" -> "text/html; charset=utf-8"
  ".js" -> "text/javascript; charset=utf-8"
  ".css" -> "text/css; charset=utf-8"
  ".json" -> "application/json"
  ".map" -> "application/json"
  ".svg" -> "image/svg+xml"
  _ -> "application/octet-stream"

-- JSON helpers --------------------------------------------------------------

errObj :: Text -> Value
errObj msg = object ["ok" .= False, "error" .= msg, "diagnostics" .= msg]

resultObj :: GenResult -> Value
resultObj r =
  object
    [ "ok" .= resOk r
    , "bindings" .= resBindings r
    , "command" .= resCommand r
    , "diagnostics" .= resDiagnostics r
    , "exitCode" .= resExitCode r
    ]

-- Config / examples ---------------------------------------------------------

loadConfig :: IO Config
loadConfig = do
  static <- fromMaybe "static" <$> lookupEnv "PLAYGROUND_STATIC_DIR"
  examples <- fromMaybe "examples" <$> lookupEnv "PLAYGROUND_EXAMPLES_DIR"
  Config
    <$> envInt "PORT" 3000
    <*> pure static
    <*> pure examples
    <*> (fromMaybe "hs-bindgen-cli" <$> lookupEnv "PLAYGROUND_CLI")
    <*> envInt "PLAYGROUND_MAX_CONCURRENT" 4
    <*> envInt "PLAYGROUND_MAX_INPUT_BYTES" 65536
    <*> envInt "PLAYGROUND_TIMEOUT_SECONDS" 10
    <*> envInteger "PLAYGROUND_MEMORY_BYTES" 2147483648
    <*> envInt "PLAYGROUND_VERBOSITY" 2
    <*> envBool "PLAYGROUND_READONLY" False
    <*> (T.pack . fromMaybe "Generation is temporarily disabled." <$> lookupEnv "PLAYGROUND_READONLY_MESSAGE")

-- | Load @*.h@ examples, sorted by filename; label strips a leading @NN-@ and @.h@.
loadExamples :: FilePath -> IO [Example]
loadExamples dir = do
  names <- sort . filter ((== ".h") . takeExtension) <$> listDirectory dir
  mapM readOne names
  where
    readOne n = do
      contents <- TIO.readFile (dir </> n)
      pure Example {exName = label (T.pack n), exBody = contents}
    label n =
      let base = fromMaybe n (T.stripSuffix ".h" n)
          noNum = T.dropWhile (`elem` ['0' .. '9']) base
       in fromMaybe noNum (T.stripPrefix "-" noNum)

-- Small utilities -----------------------------------------------------------

maxBindings, maxDiagnostics, maxFileSize, maxLineLen, maxOptionsLen :: Int
maxBindings = 512 * 1024
maxDiagnostics = 64 * 1024
maxFileSize = 16 * 1024 * 1024
maxLineLen = 1000  -- -v4 can emit multi-MB single lines (serialised AST dumps).
maxOptionsLen = 512

-- | Drop carriage returns: the PTY turns @\\n@ into @\\r\\n@ on output.
stripCR :: Text -> Text
stripCR = T.filter (/= '\r')

truncateText :: Int -> Text -> Text
truncateText n t
  | T.length t <= n = t
  | otherwise = T.take n t <> "\n… (truncated)"

-- | Cap each line, so one pathological line can't dominate the diagnostics.
trimLines :: Int -> Text -> Text
trimLines n = T.intercalate "\n" . map trim . T.lines
  where
    trim l
      | T.length l <= n = l
      | otherwise = T.take n l <> " …"

tshow :: Show a => a -> Text
tshow = T.pack . show

envInt :: String -> Int -> IO Int
envInt k d = maybe d read <$> lookupEnv k

envInteger :: String -> Integer -> IO Integer
envInteger k d = maybe d read <$> lookupEnv k

envBool :: String -> Bool -> IO Bool
envBool k d = maybe d ((`elem` ["1", "true", "yes", "on"]) . map toLower') <$> lookupEnv k
  where
    toLower' c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c
