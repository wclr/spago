module Spago.Command.Publish (publish, PublishEnv) where

import Spago.Prelude

import Affjax.Node as Http
import Affjax.RequestBody as RequestBody
import Affjax.ResponseFormat as ResponseFormat
import Affjax.StatusCode (StatusCode(..))
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Codec.Argonaut as CA
import Data.DateTime (DateTime)
import Data.Formatter.DateTime as DateTime
import Data.List as List
import Data.Map as Map
import Data.String as String
import Effect.Aff (Milliseconds(..))
import Effect.Aff as Aff
import Effect.Ref as Ref
import Node.Path as Path
import Record as Record
import Registry.API.V1 as V1
import Registry.Internal.Format as Internal.Format
import Registry.Internal.Path as Internal.Path
import Registry.Location as Location
import Registry.Metadata as Metadata
import Registry.Operation as Operation
import Registry.Operation.Validation as Operation.Validation
import Registry.PackageName as PackageName
import Registry.Version as Version
import Routing.Duplex as Duplex
import Spago.Command.Build as Build
import Spago.Command.Fetch as Fetch
import Spago.Config (Package(..), Workspace, WorkspacePackage)
import Spago.Config as Config
import Spago.Config as Core
import Spago.Db (Db)
import Spago.Git (Git)
import Spago.Git as Git
import Spago.Json as Json
import Spago.Log (LogVerbosity(..))
import Spago.Log as Log
import Spago.Purs (Purs)
import Spago.Purs.Graph as Graph

type PublishData =
  { name :: PackageName
  , location :: Maybe Location
  , ref :: String
  , compiler :: Version
  , resolutions :: Map PackageName Version
  }

type PublishEnv a =
  { getManifestFromIndex :: PackageName -> Version -> Spago (LogEnv ()) (Maybe Manifest)
  , getMetadata :: PackageName -> Spago (LogEnv ()) (Either String Metadata)
  , workspace :: Workspace
  , logOptions :: LogOptions
  , offline :: OnlineStatus
  , git :: Git
  , db :: Db
  , purs :: Purs
  , selected :: WorkspacePackage
  , dependencies :: Fetch.PackageTransitiveDeps
  | a
  }

type PublishArgs = {}

publish :: forall a. PublishArgs -> Spago (PublishEnv a) Operation.PublishData
publish _args = do
  -- We'll store all the errors here in this ref, then complain at the end
  resultRef <- liftEffect $ Ref.new (Left List.Nil)
  let
    setResult :: { expectedVersion :: Version, publishingData :: PublishData } -> _
    setResult r = liftEffect $ Ref.modify_
      ( case _ of
          Left List.Nil -> Right r
          a -> a
      )
      resultRef

    addError :: Docc -> Spago (PublishEnv a) Unit
    addError err = do
      liftEffect $ Ref.modify_
        ( case _ of
            Left errs -> Left (List.Cons err errs)
            Right _r -> Left (List.Cons err List.Nil)
        )
        resultRef

  env@
    { selected: selected'
    , purs
    , dependencies
    , logOptions
    , getMetadata
    } <- ask
  let (selected :: WorkspacePackage) = selected' { hasTests = false }
  let name = selected.package.name
  let strName = PackageName.print name
  let compiler = purs.version
  logDebug $ "Publishing package " <> strName

  -- As first thing we run a build to make sure the package compiles at all
  runSpago
    -- We explicitly list the env fields because `Record.merge` didn't compile.
    { getManifestFromIndex: env.getManifestFromIndex
    , getMetadata: env.getMetadata
    , workspace: env.workspace { selected = Just selected }
    , logOptions: env.logOptions
    , git: env.git
    , purs: env.purs
    , selected
    , dependencies: env.dependencies
    , psaCliFlags:
        { statVerbosity: (Nothing :: Maybe Core.StatVerbosity)
        , strict: (Nothing :: Maybe Boolean)
        }
    , pedanticPackages: false
    }
    ( Build.run
        { depsOnly: false
        , pursArgs: []
        , jsonErrors: false
        }
    )

  -- We then need to check that the dependency graph is accurate. If not, queue the errors
  let allDependencies = Fetch.toAllDependencies dependencies
  let globs = Build.getBuildGlobs { selected: NEA.singleton selected, withTests: false, dependencies: allDependencies, depsOnly: false }
  eitherGraph <- Graph.runGraph globs []
  case eitherGraph of
    Right graph -> do
      graphCheckErrors <- Graph.toImportErrors selected { reportSrc: true, reportTest: false } <$> runSpago (Record.union { selected } env) (Graph.checkImports graph)
      for_ graphCheckErrors (addError <<< Graph.formatImportErrors <<< pure)
    Left err ->
      die err

  -- Check if all the packages have ranges, error if not
  let
    { fail: packagesWithNoRanges, success: depsRanges' } = partitionEithers
      $ map
          ( case _ of
              Tuple pkg Nothing -> Left pkg
              Tuple pkg (Just range) -> Right (Tuple pkg range)
          )
      $ (Map.toUnfoldable :: Map _ _ -> Array _)
      $ unwrap selected.package.dependencies
    depsRanges = Map.fromFoldable depsRanges'

  unless (Array.null packagesWithNoRanges) do
    addError $ toDoc
      [ toDoc $ "The configuration is missing version bounds for some packages. Run `spago fetch --ensure-ranges` to add them:"
      , indent $ toDoc $ map (\p -> "- " <> PackageName.print p) $ Array.fromFoldable packagesWithNoRanges
      ]

  -- Solve with these ranges to get a build plan
  buildPlan <- Fetch.getTransitiveDepsFromRegistry depsRanges Map.empty

  case selected.package.publish of
    Nothing -> addError $ toDoc
      [ "Did not find publishing config: add a valid one in `package.publish`."
      , "See the configuration file's documentation: https://github.com/purescript/spago#the-configuration-file"
      ]
    Just publishConfig -> case publishConfig.location of
      Nothing -> addError $ toDoc "Need to specify a publish.location field."
      Just location -> do
        -- Get the metadata file for this package.
        -- It will exist if the package has been published at some point, it will not if the package is new.
        -- We make a new one if that's the case.
        metadata <- runSpago { logOptions } (getMetadata name) >>= case _ of
          Right (Metadata metadata) -> pure metadata
          Left err -> do
            logDebug $ "Got error while reading metadata file: " <> err
            pure
              { location
              , owners: Nothing -- TODO: get that from the config file
              , published: Map.empty
              , unpublished: Map.empty
              }
        let
          manifest =
            { name
            , location
            , description: selected.package.description
            , dependencies: depsRanges
            , version: publishConfig.version
            , license: publishConfig.license
            , owners: Nothing -- TODO specify owners in spago config
            , excludeFiles: Nothing -- TODO specify files in spago config
            , includeFiles: Nothing -- TODO specify files in spago config
            }

        unless (Operation.Validation.locationMatches (Manifest manifest) (Metadata metadata)) $ addError $ toDoc
          [ "The manifest file specifies a location ("
          , Json.stringifyJson Location.codec manifest.location
          , ") that differs from the location in the registry metadata ("
          , Json.stringifyJson Location.codec metadata.location
          , "). If you would like to change the location of your package you should "
          , "submit a transfer operation."
          ]

        -- Check that all the dependencies come from the registry
        let
          { fail, success: _ } =
            partitionEithers
              $ map
                  ( \(Tuple pkgName pkg) -> case pkg of
                      RegistryVersion v -> Right (Tuple pkgName v)
                      _ -> Left pkgName
                  )
              $ (Map.toUnfoldable allDependencies :: Array _)
        if Array.length fail > 0 then do
          addError
            $ toDoc
                [ "Some of the packages you specified as `extra_packages` do not point to the Registry."
                , "To be able to publish a package to the registry, all of its dependencies have to be packages registered on the Registry."
                , "Please replace the following packages with versions that are present in the Registry:" -- TODO point to docs
                ]
            <> toDoc (map (indent <<< toDoc <<< (append "- ") <<< Json.stringifyJson PackageName.codec) fail)
        else do
          -- All dependencies come from the registry so we can trust the build plan.
          -- We can then try to build with the dependencies from there.

          Internal.Path.readPursFiles (Path.concat [ selected.path, "src" ]) >>= case _ of
            Nothing -> addError $ toDoc
              [ "This package has no PureScript files in its `src` directory. "
              , "All package sources must be in the `src` directory, with any additional "
              , "sources indicated by the `files` key in your manifest."
              ]
            Just files -> do
              Operation.Validation.validatePursModules files >>= case _ of
                Left formattedError -> addError $ toDoc
                  [ "This package has either malformed or disallowed PureScript module names"
                  , "in its `src` directory. All package sources must be in the `src` directory,"
                  , "with any additional sources indicated by the `files` key in your manifest."
                  , formattedError
                  ]
                Right _ -> pure unit

          when (Operation.Validation.isMetadataPackage (Manifest manifest)) do
            addError $ toDoc "The `metadata` package cannot be uploaded to the registry because it is a protected package."

          for_ (Operation.Validation.isNotPublished (Manifest manifest) (Metadata metadata)) \info -> addError $ toDoc
            [ "You tried to upload a version that already exists: " <> Version.print manifest.version
            , "Its metadata is:"
            , "```json"
            , printJson Metadata.publishedMetadataCodec info
            , "```"
            ]
          for_ (Operation.Validation.isNotUnpublished (Manifest manifest) (Metadata metadata)) \info -> addError $ toDoc
            [ "You tried to upload a version that has been unpublished: " <> Version.print manifest.version
            , ""
            , "```json"
            , printJson Metadata.unpublishedMetadataCodec info
            , "```"
            ]

          -- Get the current ref
          let expectedTag = "v" <> Version.print publishConfig.version

          -- These are "soft" git tag checks. We notify the user of errors
          -- they need to fix. But these commands must not have the user
          -- 1) create/push a git tag that is known to be unpublishable, 
          --    thereby forcing them to create another git tag later with the fix.
          -- 2) input any login credentials as there are other errors to fix 
          --    before doing that.
          -- The "hard" git tag checks will occur only if these succeed.
          Git.getStatus Nothing >>= case _ of
            Left _err -> do
              die $ toDoc
                [ toDoc "Could not verify whether the git tree is clean due to the below error:"
                , indent _err
                ]
            Right statusResult
              | statusResult /= "" ->
                  addError $ toDoc
                    [ toDoc "The git tree is not clean. Please commit or stash these files:"
                    , indent $ toDoc (String.split (String.Pattern "\n") statusResult)
                    ]
              | otherwise -> do
                  -- TODO: once we ditch `purs publish`, we don't have a requirement for a tag anymore,
                  -- but we can use any ref. We can then use `getRef` here instead of `tagCheckedOut`
                  maybeCurrentTag <- hush <$> Git.tagCheckedOut Nothing
                  case maybeCurrentTag of
                    Just currentTag ->
                      when (currentTag /= expectedTag) $ addError $ toDoc
                        [ "The tag (" <> currentTag <> ") does not match the expected tag (" <> expectedTag <> ")."
                        , "Fix all other publishing-related errors first before creating the correct tag. Do not push your created tag to its remote. Prematurely creating and pushing a tag can lead to unpublishable tags."
                        , ""
                        , "To create the tag, you can run:"
                        , ""
                        , "  git tag " <> expectedTag
                        ]
                    Nothing ->
                      -- Current commit does not refer to a git tag.
                      -- We should see whether the expected tag was already defined
                      Git.listTags Nothing >>= case _ of
                        Left err ->
                          die $ toDoc
                            [ toDoc "Cannot check whether publish config's `version` matches any existing git tags due to the below error:"
                            , err
                            ]
                        Right tags -> do
                          let
                            tagExists = Array.any (eq expectedTag) tags
                            emptyUnless b xs = if b then [] else xs
                          when tagExists $ addError $ toDoc
                            [ "The expected tag (" <> expectedTag <> ") has already been defined but is not checked out."
                            , "The publish config's `version` may need to be bumped to a newer version if it currently refers to a version that has already been published."
                            ]
                          addError $ toDoc
                            $
                              [ "No git tag is currently checked out."
                              , "Please fix all other publishing-related errors before resolving this one. Prematurely creating and pushing a tag may lead to unpublishable tags."
                              ]
                            <> emptyUnless tagExists
                              [ "To create the tag, you can run:"
                              , ""
                              , "  git tag " <> expectedTag
                              ]

          setResult
            { expectedVersion: publishConfig.version
            , publishingData: { name, location: Just location, ref: expectedTag, compiler, resolutions: buildPlan }
            }

  result <- liftEffect $ Ref.read resultRef
  case result of
    Left errors -> do
      logError
        $ Log.bold
            ( toDoc
                $ "Your package "
                <> show strName
                <> " is not ready for publishing yet, encountered "
                <> show (List.length errors)
                <> if (List.length errors == 1) then " error:" else " errors:"
            )
        <> Log.break
      die' $ Array.fromFoldable errors
    Right { expectedVersion, publishingData: publishingData@{ resolutions } } -> do
      logInfo "Passed preliminary checks. "
      -- This requires login credentials. 
      Git.pushTag Nothing expectedVersion >>= case _ of
        Left err -> die $ toDoc
          [ err
          , toDoc "You can try to push the tag manually by running:"
          , toDoc ""
          , toDoc $ "  git push origin v" <> Version.print expectedVersion
          ]
        Right _ -> pure unit

      -- Once we are sure that no errors will be produced we can try building with the build plan
      -- from the solver (this is because the build might terminate the process, and we shall output the errors first)
      logInfo "Building again with the build plan from the solver..."
      let buildPlanDependencies = map Config.RegistryVersion resolutions
      runSpago
        -- We explicitly list the env fields because `Record.merge` didn't compile.
        { getManifestFromIndex: env.getManifestFromIndex
        , getMetadata: env.getMetadata
        , workspace: env.workspace { selected = Just selected }
        , logOptions: env.logOptions
        , git: env.git
        , purs: env.purs
        , selected: env.selected
        , dependencies: Map.singleton selected.package.name buildPlanDependencies
        , psaCliFlags:
            { statVerbosity: (Nothing :: Maybe Core.StatVerbosity)
            , strict: (Nothing :: Maybe Boolean)
            }
        , pedanticPackages: false
        }
        ( Build.run
            { depsOnly: false
            , pursArgs: []
            , jsonErrors: false
            }
        )

      logDebug $ unsafeStringify publishingData
      logSuccess "Ready for publishing. Calling the registry.."

      let newPublishingData = publishingData { resolutions = Just publishingData.resolutions } :: Operation.PublishData

      { jobId } <- callRegistry (baseApi <> Duplex.print V1.routes V1.Publish) V1.jobCreatedResponseCodec (Just { codec: Operation.publishCodec, data: newPublishingData })
      logSuccess $ "Registry accepted the Publish request and is processing..."
      logDebug $ "Job ID: " <> unwrap jobId
      logInfo "Logs from the Registry pipeline:"
      waitForJobFinish jobId

      pure newPublishingData

callRegistry :: forall env a b. String -> JsonCodec b -> Maybe { codec :: JsonCodec a, data :: a } -> Spago (PublishEnv env) b
callRegistry url outputCodec maybeInput = handleError do
  logDebug $ "Calling registry at " <> url
  response <- liftAff $ withBackoff' $ case maybeInput of
    Just { codec: inputCodec, data: input } -> Http.post ResponseFormat.string url (Just $ RequestBody.json $ CA.encode inputCodec input)
    Nothing -> Http.get ResponseFormat.string url
  case response of
    Nothing -> pure $ Left $ "Could not reach the registry at " <> url
    Just (Left err) -> pure $ Left $ "Error while calling the registry:\n  " <> Http.printError err
    Just (Right { status, body }) | status /= StatusCode 200 -> do
      pure $ Left $ "Registry did not like this and answered with status " <> show status <> ", got answer:\n  " <> body
    Just (Right { body }) -> do
      pure $ case parseJson outputCodec body of
        Right output -> Right output
        Left err -> Left $ "Could not parse response from the registry, error: " <> show err
  where
  -- TODO: see if we want to just kill the process generically here, or give out customized errors
  handleError a = do
    { offline } <- ask
    case offline of
      Offline -> die "Spago is offline - not able to call the Registry."
      Online ->
        a >>= case _ of
          Left err -> die err
          Right res -> pure res

waitForJobFinish :: forall env. V1.JobId -> Spago (PublishEnv env) Unit
waitForJobFinish jobId = go Nothing
  where
  go :: Maybe DateTime -> Spago (PublishEnv env) Unit
  go lastTimestamp = do
    { logOptions } <- ask
    let
      url = baseApi <> Duplex.print V1.routes
        ( V1.Job jobId
            { since: lastTimestamp
            , level: case logOptions.verbosity of
                LogVerbose -> Just V1.Debug
                _ -> Just V1.Info
            }
        )
    jobInfo :: V1.Job <- callRegistry url V1.jobCodec Nothing
    -- first of all, print all the logs we get
    for_ jobInfo.logs \log -> do
      let line = Log.indent $ toDoc $ DateTime.format Internal.Format.iso8601DateTime log.timestamp <> " " <> log.message
      case log.level of
        V1.Debug -> logDebug line
        V1.Info -> logInfo line
        V1.Warn -> logWarn line
        V1.Error -> logError line
    case jobInfo.finishedAt of
      Nothing -> do
        -- If the job is not finished, we grab the timestamp of the last log line, wait a bit and retry
        let
          latestTimestamp = jobInfo.logs # Array.last # case _ of
            Just log -> Just log.timestamp
            Nothing -> lastTimestamp
        liftAff $ Aff.delay $ Milliseconds 500.0
        go latestTimestamp
      Just _finishedAt -> do
        -- if it's done we report the failure.
        logDebug $ "Job: " <> printJson V1.jobCodec jobInfo
        case jobInfo.success of
          true -> logSuccess $ "Registry finished processing the package. Your package was published successfully!"
          false -> die $ "Registry finished processing the package, but it failed. Please fix it and try again."

baseApi :: String
baseApi = "https://registry.purescript.org"
