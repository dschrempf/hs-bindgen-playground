{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | hs-bindgen playground: a scotty server that shells out to the Nix-built
-- @hs-bindgen-cli@ inside a bubblewrap sandbox and returns generated bindings.
module Main (main) where

import Control.Concurrent.STM
import Control.Exception (finally)
import Control.Monad (unless, when)
import Data.Aeson
  ( FromJSON (..),
    Value,
    object,
    withObject,
    (.!=),
    (.:),
    (.:?),
    (.=),
  )
import Data.ByteString qualified as BS
import Data.Char (isAlphaNum, isSpace, isUpper)
import Data.List (sort)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Text.IO qualified as TIO
import Data.Text.Lazy qualified as TL
import Network.HTTP.Types (status403, status413, status503)
import Network.Wai (Middleware, pathInfo)
import Network.Wai.Middleware.RequestSizeLimit
  ( defaultRequestSizeLimitSettings,
    requestSizeLimitMiddleware,
    setMaxLengthForRequest,
  )
import Network.Wai.Request (RequestSizeException (..))
import System.Directory
  ( createDirectoryIfMissing,
    doesFileExist,
    listDirectory,
  )
import System.Environment (getEnv, lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath (takeExtension, (</>))
import System.IO (IOMode (..), hFlush, hIsTerminalDevice, openFile, stdout)
import System.IO.Temp (withSystemTempDirectory)
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
  )
import Web.Scotty

-- | Runtime configuration, all from the environment (see 'loadConfig').
data Config = Config
  { cfgPort :: Int,
    cfgStaticDir :: FilePath,
    cfgExamplesDir :: FilePath,
    cfgCli :: String,
    cfgStoreBind :: StoreBind,
    cfgMaxConcurrent :: Int,
    cfgMaxInputBytes :: Int,
    cfgTimeoutSecs :: Int,
    -- | prlimit --as (address space)
    cfgMemBytes :: Integer,
    cfgVerbosity :: Int,
    cfgReadOnly :: Bool,
    cfgReadOnlyMsg :: Text,
    cfgComponents :: [Component]
  }

-- | A versioned part of the running instance, shown in the UI header: this
-- server and the @hs-bindgen@ it generates with. Both come from the Nix build
-- (see @nix\/package.nix@), which alone knows the revisions.
data Component = Component
  { compName :: Text,
    compVersion :: Text,
    compRevision :: Revision,
    -- | GitHub repository, no trailing slash; @\/commit\/<rev>@ is appended.
    compRepo :: Text
  }

-- | The git revision a component was built from.
data Revision
  = -- | Built from a clean tree: the commit exists upstream, so link it.
    CleanRev Text
  | -- | Built with uncommitted changes; show the base revision, but no link —
    -- the running code is not what that commit contains.
    DirtyRev Text
  | -- | Nix had no revision to report (a build from a plain, non-git path).
    NoRev

-- | What of the Nix store the sandbox may read.
data StoreBind
  = -- | Bind exactly these paths — the runtime closure of everything the server
    -- shells out to, from the file @PLAYGROUND_STORE_PATHS@ names. Keeps a
    -- crafted @#include@ from reading unrelated store paths (the system closure,
    -- anything a future module puts there) and echoing them back as diagnostics.
    BindClosure [FilePath]
  | -- | Bind all of @\/nix\/store@. Only reached with @PLAYGROUND_STORE_PATHS@
    -- unset, i.e. running the unwrapped binary with no environment; the flake
    -- sets the variable for both @cabal run@ and the wrapped package.
    BindWholeStore

-- | A curated example header shown in the UI dropdown.
data Example = Example
  { exName :: Text,
    exBody :: Text
  }

-- | A parsed generation request from the frontend.
data GenReq = GenReq
  { reqSource :: Text,
    reqStd :: Text,
    reqSafe :: Bool,
    reqModule :: Text,
    -- | 0–4; 'Nothing' falls back to 'cfgVerbosity'.
    reqVerbosity :: Maybe Int,
    reqMacroWarnings :: Bool,
    -- | free-form extra @preprocess@ options (quote-aware).
    reqExtraOpts :: Text
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

-- | One extra @preprocess@ option, already checked against 'allowedOpts'.
data ExtraOpt = ExtraOpt
  { optFlag :: Text,
    optArgs :: [Text]
  }

-- | A validated request, ready to run: every free-form field of 'GenReq' parsed
-- into what the CLI will actually receive.
data Job = Job
  { jobSource :: Text,
    jobStd :: Text,
    jobSafe :: Bool,
    jobModule :: Text,
    jobVerbosity :: Int,
    jobMacroWarnings :: Bool,
    jobExtraOpts :: [ExtraOpt]
  }

-- | How a sandboxed run ended, as far as the UI cares.
data Outcome
  = -- | The CLI exited cleanly and wrote the module.
    Generated
  | -- | The @timeout@ wrapper killed the chain.
    TimedOut
  | -- | The CLI reported an error, or wrote no module.
    Failed

-- | Result of a successful (or failed-but-ran) generation.
data GenResult = GenResult
  { resOk :: Bool,
    resBindings :: Text,
    resCommand :: Text,
    resDiagnostics :: Text,
    resExitCode :: Int
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
  -- Unconditional: it answers "what is deployed?" from the journal too.
  TIO.putStrLn $ T.intercalate ", " (map displayComponent (cfgComponents cfg))
  when interactive $
    putStrLn $
      "hs-bindgen playground: http://localhost:" <> show (cfgPort cfg) <> "/"
  hFlush stdout -- a pipe to the journal is block-buffered
  scotty (cfgPort cfg) $ do
    middleware (bodyLimit cfg)

    -- 'bodyLimit' aborts an over-large body by throwing 'RequestSizeException'
    -- from the body reader; scotty doesn't know that type, so without this it
    -- would surface as a bare 500. Render it as the frontend's JSON error shape.
    defaultHandler $ Handler $ \(RequestSizeException maxLen) -> do
      status status413
      json $ errObj ("Request too large (limit " <> tshow maxLen <> " bytes).")

    get "/" $ do
      setHeader "Content-Type" "text/html; charset=utf-8"
      file (cfgStaticDir cfg </> "index.html")

    staticRoute (cfgStaticDir cfg)

    get "/api/config" $
      json $
        object
          [ "readOnly" .= cfgReadOnly cfg,
            "message" .= cfgReadOnlyMsg cfg,
            "versions" .= map componentObj (cfgComponents cfg)
          ]

    get "/api/examples" $
      json [object ["name" .= exName e, "body" .= exBody e] | e <- examples]

    post "/api/generate" $ handleGenerate cfg gate

-- | Reject an over-large request body while it streams in, before any handler
-- buffers it — a coarse DoS backstop below the per-field 'cfgMaxInputBytes'
-- check. It counts bytes as they arrive (so a chunked body with no
-- @Content-Length@ is caught too), unlike the source-size check, which runs only
-- after the whole body is parsed. The cap is generous: JSON escaping can inflate
-- a 'cfgMaxInputBytes' source several-fold, and the body also carries the JSON
-- envelope and other fields. Applies regardless of any fronting proxy.
bodyLimit :: Config -> Middleware
bodyLimit cfg =
  requestSizeLimitMiddleware $
    setMaxLengthForRequest (\_ -> pure (Just limit)) defaultRequestSizeLimitSettings
  where
    limit = fromIntegral (cfgMaxInputBytes cfg) * 8 + 65536

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
        else case validate cfg req of
          Left msg -> do
            status status403
            json (errObj msg)
          Right job -> do
            mres <- liftIO $ withGate gate (runGenerate cfg job)
            case mres of
              Nothing -> do
                status status503
                json (errObj "Server busy — please try again in a moment.")
              Just res -> json (resultObj res)

-- | Turn a wire 'GenReq' into a 'Job', rejecting anything the CLI shouldn't see.
validate :: Config -> GenReq -> Either Text Job
validate cfg req = do
  let m = reqModule req
  unless
    (not (T.null m) && isUpper (T.head m) && T.all (\c -> isAlphaNum c || c == '_') m)
    (Left "Module name must start with an uppercase letter and contain only letters, digits, or underscores.")
  unless
    (reqStd req `elem` allowedStds)
    (Left $ "Unsupported C standard: " <> reqStd req <> ".")
  verbosity <- case reqVerbosity req of
    Nothing -> Right (cfgVerbosity cfg)
    Just v
      | v >= 0 && v <= 4 -> Right v
      | otherwise -> Left "Verbosity must be between 0 and 4."
  unless
    (T.length (reqExtraOpts req) <= maxOptionsLen)
    (Left $ "Additional options too long (limit " <> tshow maxOptionsLen <> " chars).")
  opts <- parseExtraOpts (reqExtraOpts req)
  pure
    Job
      { jobSource = reqSource req,
        jobStd = reqStd req,
        jobSafe = reqSafe req,
        jobModule = m,
        jobVerbosity = verbosity,
        jobMacroWarnings = reqMacroWarnings req,
        jobExtraOpts = opts
      }

allowedStds :: [Text]
allowedStds = ["c89", "c99", "c11", "c17", "c23"]

-- | The extra @preprocess@ options the UI may add, with each one's argument
-- count. Deliberately excluded: anything naming a file or an include directory,
-- anything forwarded to clang (@--clang-option@ and friends), and anything
-- 'cliArgs' already fixes. Without that restriction the field hands anonymous
-- users the whole clang command line — @--clang-option=-I\/etc@ turns a crafted
-- @#include@ into a file-read primitive whose contents come back as diagnostics.
allowedOpts :: [(Text, Int)]
allowedOpts =
  [ ("--fblocks", 0),
    ("--no-stdlib", 0),
    ("--binding-spec-allow-newer", 0),
    ("--select-all", 0),
    ("--select-from-main-headers", 0),
    ("--select-from-main-header-dirs", 0),
    ("--select-except-deprecated", 0),
    ("--enable-program-slicing", 0),
    ("--omit-field-prefixes", 0),
    ("--parse-empty-macros", 0),
    ("--post-qualified-imports", 0),
    -- PCRE arguments are attacker-controlled, but a pathological pattern only
    -- burns the job's own prlimit --cpu budget.
    ("--select-by-header-path", 1),
    ("--select-except-by-header-path", 1),
    ("--select-by-decl-name", 1),
    ("--select-except-by-decl-name", 1),
    ("--path-style", 1),
    ("--hash-define", 2)
  ]

-- | Parse the free-form options string into checked 'ExtraOpt's.
parseExtraOpts :: Text -> Either Text [ExtraOpt]
parseExtraOpts = go . map T.pack . splitArgs
  where
    go [] = Right []
    go (tok : rest) = case lookup tok allowedOpts of
      Nothing ->
        Left $
          "Option not allowed: "
            <> tok
            <> ". Accepted: "
            <> T.intercalate ", " (map fst allowedOpts)
            <> "."
      Just n
        | length args < n ->
            Left $ tok <> " takes " <> tshow n <> " argument(s)."
        | otherwise -> (ExtraOpt tok args :) <$> go rest'
        where
          (args, rest') = splitAt n rest

-- | Run the CLI in the sandbox against the request's source, in a fresh temp dir.
runGenerate :: Config -> Job -> IO GenResult
runGenerate cfg job =
  withSystemTempDirectory "playground" $ \tmp -> do
    let work = tmp </> "work"
        outDir = work </> "out"
        outFile = outDir </> T.unpack (jobModule job) <> ".hs"
    createDirectoryIfMissing True outDir
    TIO.writeFile (work </> "input.h") (jobSource job)
    ownPath <- getEnv "PATH"
    let sandboxArgs = buildArgv cfg job work ownPath
    -- Capture stderr, where the CLI writes diagnostics; @--color always@ (in
    -- 'cliArgs') forces the ANSI escapes even though stderr is a plain pipe.
    (ec, out) <- runCapture "timeout" sandboxArgs
    haveOut <- doesFileExist outFile
    bindings <- if haveOut then TIO.readFile outFile else pure ""
    let outcome = classify ec haveOut
        code = case ec of ExitSuccess -> 0; ExitFailure n -> n
    pure
      GenResult
        { resOk = case outcome of Generated -> True; _ -> False,
          resBindings = truncateText maxBindings bindings,
          resCommand = displayCommand job,
          resDiagnostics = trimLines (annotate outcome out),
          resExitCode = code
        }
  where
    -- @timeout --signal=KILL@ re-raises SIGKILL on itself, so waitForProcess
    -- reports -9; a shell renders that same death as 137.
    classify ExitSuccess haveOut = if haveOut then Generated else Failed
    classify (ExitFailure n) _
      | n == -9 || n == 137 = TimedOut
      | otherwise = Failed
    annotate TimedOut d =
      d
        <> "\n[playground] Killed: exceeded the "
        <> tshow (cfgTimeoutSecs cfg)
        <> "s time limit."
    annotate _ d = d

-- | Arguments to @timeout@, chaining @timeout → prlimit → bwrap → hs-bindgen-cli@.
buildArgv :: Config -> Job -> FilePath -> String -> [String]
buildArgv cfg job work ownPath =
  ["--signal=KILL", show (cfgTimeoutSecs cfg) <> "s"]
    ++ [ "prlimit",
         "--as=" <> show (cfgMemBytes cfg),
         "--cpu=" <> show (cfgTimeoutSecs cfg),
         "--fsize=" <> show maxFileSize,
         "--nofile=256",
         "--"
       ]
    ++ ["bwrap"]
    ++ bwrapArgs
    ++ ["--"]
    ++ [cfgCli cfg]
    ++ cliArgs job
  where
    storeBindArgs = case cfgStoreBind cfg of
      BindWholeStore -> ["--ro-bind", "/nix/store", "/nix/store"]
      BindClosure ps -> concat [["--ro-bind", p, p] | p <- ps]
    bwrapArgs =
      [ "--unshare-all",
        -- --disable-userns needs an explicit --unshare-user (the implicit one
        -- from --unshare-all does not satisfy it); together they let bwrap set
        -- up its own user namespace but block the sandboxed process from
        -- creating nested ones, removing the userns kernel attack surface from
        -- anything running inside.
        "--unshare-user",
        "--disable-userns",
        "--die-with-parent",
        "--new-session",
        "--clearenv",
        "--setenv",
        "PATH",
        ownPath,
        "--setenv",
        "TMPDIR",
        "/tmp",
        "--setenv",
        "HOME",
        "/work"
      ]
        ++ storeBindArgs
        ++ [ "--proc",
             "/proc",
             "--dev",
             "/dev",
             "--tmpfs",
             "/tmp",
             "--bind",
             work,
             "/work",
             "--chdir",
             "/work"
           ]

-- | Run @cmd args@ capturing its stderr (where the CLI writes diagnostics),
-- decoded leniently as UTF-8. Reading stderr to EOF before reaping avoids a
-- full-pipe deadlock.
--
-- Stdin\/stdout go to @\/dev\/null@ rather than 'NoStream', which would *close*
-- the child's fd 1: with stdout closed the CLI hangs on its error path, so every
-- failed generation would stall until 'cfgTimeoutSecs' kills it.
runCapture :: String -> [String] -> IO (ExitCode, Text)
runCapture cmd args = do
  -- 'UseHandle' closes these in the parent once the child holds them.
  devNullIn <- openFile "/dev/null" ReadMode
  devNullOut <- openFile "/dev/null" WriteMode
  (_, _, mErr, ph) <-
    createProcess
      (proc cmd args)
        { std_in = UseHandle devNullIn,
          std_out = UseHandle devNullOut,
          std_err = CreatePipe,
          close_fds = True
        }
  out <- case mErr of
    Just hErr -> TE.decodeUtf8With lenientDecode <$> BS.hGetContents hErr
    Nothing -> pure ""
  ec <- waitForProcess ph
  pure (ec, out)

-- | Split a free-form option string into tokens, honouring single/double quotes
-- (which group and are stripped). No shell involved — 'parseExtraOpts' checks
-- the tokens and 'createProcess' takes an argv list — so there is nothing to
-- escape and no injection.
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
cliArgs :: Job -> [String]
cliArgs job =
  ["-v", show (jobVerbosity job)]
    ++ ["--color", "always"] -- force ANSI diagnostics; stderr is a pipe, not a tty
    ++ ["--log-enable-macro-warnings" | jobMacroWarnings job]
    ++ [ "preprocess",
         "--single-file",
         if jobSafe job then "--safe" else "--unsafe",
         "",
         "--unique-id",
         "playground.hs-bindgen",
         "--module",
         T.unpack (jobModule job),
         "--hs-output-dir",
         "/work/out",
         "--create-output-dirs",
         "--overwrite-files",
         "--clang-option=-std=" <> T.unpack (jobStd job)
       ]
    ++ concatMap extraOptArgv (jobExtraOpts job)
    ++ ["-I", "/work", "input.h"]

extraOptArgv :: ExtraOpt -> [String]
extraOptArgv o = map T.unpack (optFlag o : optArgs o)

-- | A human-readable, copy-pasteable version of the CLI command for the UI.
-- Paths are shown relative (@out@, @.@) rather than the sandbox @\/work@ ones.
displayCommand :: Job -> Text
displayCommand job =
  T.intercalate " \\\n  " $
    map
      T.pack
      [ "hs-bindgen-cli -v "
          <> show (jobVerbosity job)
          <> " --color always"
          <> (if jobMacroWarnings job then " --log-enable-macro-warnings" else "")
          <> " preprocess",
        "--single-file " <> (if jobSafe job then "--safe" else "--unsafe") <> " ''",
        "--unique-id playground.hs-bindgen",
        "--module " <> T.unpack (jobModule job),
        "--hs-output-dir out --create-output-dirs --overwrite-files",
        "--clang-option=-std=" <> T.unpack (jobStd job)
      ]
      ++ map showOpt (jobExtraOpts job)
      ++ ["-I . input.h"]
  where
    showOpt o = T.unwords (optFlag o : map quote (optArgs o))
    quote a
      | T.null a || T.any isSpace a = "'" <> a <> "'"
      | otherwise = a

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

-- | A component for the UI: @commitUrl@ is 'Data.Aeson.Null' unless the
-- revision is clean, so the frontend links exactly when there is a commit to
-- link to.
componentObj :: Component -> Value
componentObj c =
  object
    [ "name" .= compName c,
      "version" .= compVersion c,
      "revision" .= revision,
      "commitUrl" .= commitUrl
    ]
  where
    (revision, commitUrl) = case compRevision c of
      CleanRev r -> (Just r, Just (compRepo c <> "/commit/" <> r))
      DirtyRev r -> (Just (r <> "-dirty"), Nothing)
      NoRev -> (Nothing, Nothing)

resultObj :: GenResult -> Value
resultObj r =
  object
    [ "ok" .= resOk r,
      "bindings" .= resBindings r,
      "command" .= resCommand r,
      "diagnostics" .= resDiagnostics r,
      "exitCode" .= resExitCode r
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
    <*> loadStoreBind
    <*> envInt "PLAYGROUND_MAX_CONCURRENT" 4
    <*> envInt "PLAYGROUND_MAX_INPUT_BYTES" 65536
    <*> envInt "PLAYGROUND_TIMEOUT_SECONDS" 10
    <*> envInteger "PLAYGROUND_MEMORY_BYTES" 2147483648
    <*> envInt "PLAYGROUND_VERBOSITY" 2
    <*> envBool "PLAYGROUND_READONLY" False
    <*> (T.pack . fromMaybe "Generation is temporarily disabled." <$> lookupEnv "PLAYGROUND_READONLY_MESSAGE")
    <*> loadComponents

-- | Read the two components' versions from the environment the Nix wrapper (and
-- the dev shell) sets. Unset means an unwrapped binary run by hand: say "dev"
-- rather than invent a version.
loadComponents :: IO [Component]
loadComponents =
  sequence
    [ component "playground" "PLAYGROUND_VERSION" "PLAYGROUND_REVISION" playgroundRepo,
      component "hs-bindgen" "PLAYGROUND_HS_BINDGEN_VERSION" "PLAYGROUND_HS_BINDGEN_REVISION" hsBindgenRepo
    ]
  where
    component name verKey revKey repo = do
      ver <- lookupEnv verKey
      rev <- lookupEnv revKey
      pure
        Component
          { compName = name,
            compVersion = maybe "dev" T.pack ver,
            compRevision = parseRevision (maybe "" T.pack rev),
            compRepo = repo
          }

playgroundRepo, hsBindgenRepo :: Text
playgroundRepo = "https://github.com/dschrempf/hs-bindgen-playground"
hsBindgenRepo = "https://github.com/well-typed/hs-bindgen"

-- | Classify what Nix reported: @\"\"@\/@\"unknown\"@ (no git), @\"abc1234-dirty\"@
-- (uncommitted changes), or a plain short revision.
parseRevision :: Text -> Revision
parseRevision t
  | T.null t || t == "unknown" = NoRev
  | Just base <- T.stripSuffix "-dirty" t = DirtyRev base
  | otherwise = CleanRev t

-- | @playground 0.1.0 (cabde71)@ — the header line, also logged at startup.
displayComponent :: Component -> Text
displayComponent c = compName c <> " " <> compVersion c <> rev
  where
    rev = case compRevision c of
      CleanRev r -> " (" <> r <> ")"
      DirtyRev r -> " (" <> r <> "-dirty)"
      NoRev -> ""

-- | Read the sandbox's store allowlist from the file @PLAYGROUND_STORE_PATHS@
-- names (Nix' @closureInfo@ writes one path per line; @nix\/package.nix@ points
-- the variable at it). Unset means nothing told us what the closure is, so fall
-- back to the whole store rather than a sandbox missing the CLI.
loadStoreBind :: IO StoreBind
loadStoreBind =
  lookupEnv "PLAYGROUND_STORE_PATHS" >>= \case
    Nothing -> pure BindWholeStore
    Just f -> do
      ls <- map T.strip . T.lines <$> TIO.readFile f
      pure $ BindClosure [T.unpack l | l <- ls, not (T.null l)]

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

maxBindings, maxFileSize, maxLineLen, maxLines, maxOptionsLen :: Int
maxBindings = 512 * 1024
maxFileSize = 16 * 1024 * 1024
maxLineLen = 1000 -- -v4 can emit multi-MB single lines (serialised AST dumps),
maxLines = 10000 -- and very many of them; cap the count, but keep every line otherwise.
maxOptionsLen = 512

truncateText :: Int -> Text -> Text
truncateText n t
  | T.length t <= n = t
  | otherwise = T.take n t <> "\n… (truncated)"

-- | Truncate over-long lines and cap the total line count, so a pathological
-- line (or a multi-MB -v4 dump) can't dominate the diagnostics — but every line
-- within the count is shown, rather than the whole buffer being cut mid-output.
trimLines :: Text -> Text
trimLines t = T.intercalate "\n" (map trim shown <> note)
  where
    ls = T.lines t
    shown = take maxLines ls
    dropped = length ls - length shown
    note
      | dropped <= 0 = []
      | otherwise = ["… (" <> tshow dropped <> " more lines truncated)"]
    trim l
      | T.length l <= maxLineLen = l
      | otherwise = T.take maxLineLen l <> " … (truncated) "

tshow :: (Show a) => a -> Text
tshow = T.pack . show

envInt :: String -> Int -> IO Int
envInt k d = maybe d read <$> lookupEnv k

envInteger :: String -> Integer -> IO Integer
envInteger k d = maybe d read <$> lookupEnv k

envBool :: String -> Bool -> IO Bool
envBool k d = maybe d ((`elem` ["1", "true", "yes", "on"]) . map toLower') <$> lookupEnv k
  where
    toLower' c = if c >= 'A' && c <= 'Z' then toEnum (fromEnum c + 32) else c
