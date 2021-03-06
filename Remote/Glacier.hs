{- Amazon Glacier remotes.
 -
 - Copyright 2012 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU GPL version 3 or higher.
 -}

module Remote.Glacier (remote, jobList) where

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as L

import Common.Annex
import Types.Remote
import Types.Key
import qualified Git
import Config
import Config.Cost
import Remote.Helper.Special
import qualified Remote.Helper.AWS as AWS
import Creds
import Utility.Metered
import qualified Annex
import Annex.UUID
import Utility.Env

type Vault = String
type Archive = FilePath

remote :: RemoteType
remote = RemoteType {
	typename = "glacier",
	enumerate = findSpecialRemotes "glacier",
	generate = gen,
	setup = glacierSetup
}

gen :: Git.Repo -> UUID -> RemoteConfig -> RemoteGitConfig -> Annex (Maybe Remote)
gen r u c gc = new <$> remoteCost gc veryExpensiveRemoteCost
  where
	new cst = Just $ specialRemote' specialcfg c
		(prepareStore this)
		(prepareRetrieve this)
		(simplyPrepare $ remove this)
		(simplyPrepare $ checkKey this)
		this
	  where
		this = Remote {
			uuid = u,
			cost = cst,
			name = Git.repoDescribe r,
			storeKey = storeKeyDummy,
			retrieveKeyFile = retreiveKeyFileDummy,
			retrieveKeyFileCheap = retrieveCheap this,
			removeKey = removeKeyDummy,
			checkPresent = checkPresentDummy,
			checkPresentCheap = False,
			whereisKey = Nothing,
			remoteFsck = Nothing,
			repairRepo = Nothing,
			config = c,
			repo = r,
			gitconfig = gc,
			localpath = Nothing,
			readonly = False,
			availability = GloballyAvailable,
			remotetype = remote,
			mkUnavailable = return Nothing,
			getInfo = includeCredsInfo c (AWS.creds u) $
				[ ("glacier vault", getVault c) ]
		}
	specialcfg = (specialRemoteCfg c)
		-- Disabled until jobList gets support for chunks.
		{ chunkConfig = NoChunks
		}

glacierSetup :: Maybe UUID -> Maybe CredPair -> RemoteConfig -> Annex (RemoteConfig, UUID)
glacierSetup mu mcreds c = do
	u <- maybe (liftIO genUUID) return mu
	glacierSetup' (isJust mu) u mcreds c
glacierSetup' :: Bool -> UUID -> Maybe CredPair -> RemoteConfig -> Annex (RemoteConfig, UUID)
glacierSetup' enabling u mcreds c = do
	(c', encsetup) <- encryptionSetup c
	c'' <- setRemoteCredPair encsetup c' (AWS.creds u) mcreds
	let fullconfig = c'' `M.union` defaults
	unless enabling $
		genVault fullconfig u
	gitConfigSpecialRemote u fullconfig "glacier" "true"
	return (fullconfig, u)
  where
	remotename = fromJust (M.lookup "name" c)
	defvault = remotename ++ "-" ++ fromUUID u
	defaults = M.fromList
		[ ("datacenter", T.unpack $ AWS.defaultRegion AWS.Glacier)
		, ("vault", defvault)
		]

prepareStore :: Remote -> Preparer Storer
prepareStore r = checkPrepare nonEmpty (byteStorer $ store r)

nonEmpty :: Key -> Annex Bool
nonEmpty k
	| keySize k == Just 0 = do
		warning "Cannot store empty files in Glacier."
		return False
	| otherwise = return True

store :: Remote -> Key -> L.ByteString -> MeterUpdate -> Annex Bool
store r k b p = go =<< glacierEnv c u
  where
	c = config r
	u = uuid r
	params = glacierParams c
		[ Param "archive"
		, Param "upload"
		, Param "--name", Param $ archive r k
		, Param $ getVault $ config r
		, Param "-"
		]
	go Nothing = return False
	go (Just e) = do
		let cmd = (proc "glacier" (toCommand params)) { env = Just e }
		liftIO $ catchBoolIO $
			withHandle StdinHandle createProcessSuccess cmd $ \h -> do
				meteredWrite p h b
				return True

prepareRetrieve :: Remote -> Preparer Retriever
prepareRetrieve = simplyPrepare . byteRetriever . retrieve

retrieve :: Remote -> Key -> (L.ByteString -> Annex Bool) -> Annex Bool
retrieve r k sink = go =<< glacierEnv c u
  where
	c = config r
	u = uuid r
	params = glacierParams c
		[ Param "archive"
		, Param "retrieve"
		, Param "-o-"
		, Param $ getVault $ config r
		, Param $ archive r k
		]
	go Nothing = error "cannot retrieve from glacier"
	go (Just e) = do
		let cmd = (proc "glacier" (toCommand params))
			{ env = Just e
			, std_out = CreatePipe
			}
		(_, Just h, _, pid) <- liftIO $ createProcess cmd
		-- Glacier cannot store empty files, so if the output is
		-- empty, the content is not available yet.
		ok <- ifM (liftIO $ hIsEOF h)
			( return False
			, sink =<< liftIO (L.hGetContents h)
			)
		liftIO $ hClose h
		liftIO $ forceSuccessProcess cmd pid
		unless ok $ do
			showLongNote "Recommend you wait up to 4 hours, and then run this command again."
		return ok

retrieveCheap :: Remote -> Key -> FilePath -> Annex Bool
retrieveCheap _ _ _ = return False

remove :: Remote -> Remover
remove r k = glacierAction r
	[ Param "archive"
	
	, Param "delete"
	, Param $ getVault $ config r
	, Param $ archive r k
	]

checkKey :: Remote -> CheckPresent
checkKey r k = do
	showAction $ "checking " ++ name r
	go =<< glacierEnv (config r) (uuid r)
  where
	go Nothing = error "cannot check glacier"
	go (Just e) = do
		{- glacier checkpresent outputs the archive name to stdout if
		 - it's present. -}
		s <- liftIO $ readProcessEnv "glacier" (toCommand params) (Just e)
		let probablypresent = key2file k `elem` lines s
		if probablypresent
			then ifM (Annex.getFlag "trustglacier")
				( return True, error untrusted )
			else return False

	params = glacierParams (config r)
		[ Param "archive"
		, Param "checkpresent"
		, Param $ getVault $ config r
		, Param "--quiet"
		, Param $ archive r k
		]

	untrusted = unlines
			[ "Glacier's inventory says it has a copy."
			, "However, the inventory could be out of date, if it was recently removed."
			, "(Use --trust-glacier if you're sure it's still in Glacier.)"
			, ""
			]

glacierAction :: Remote -> [CommandParam] -> Annex Bool
glacierAction r = runGlacier (config r) (uuid r)

runGlacier :: RemoteConfig -> UUID -> [CommandParam] -> Annex Bool
runGlacier c u params = go =<< glacierEnv c u
  where
	go Nothing = return False
	go (Just e) = liftIO $
		boolSystemEnv "glacier" (glacierParams c params) (Just e)

glacierParams :: RemoteConfig -> [CommandParam] -> [CommandParam]
glacierParams c params = datacenter:params
  where
	datacenter = Param $ "--region=" ++
		fromMaybe (error "Missing datacenter configuration")
			(M.lookup "datacenter" c)

glacierEnv :: RemoteConfig -> UUID -> Annex (Maybe [(String, String)])
glacierEnv c u = go =<< getRemoteCredPairFor "glacier" c creds
  where
	go Nothing = return Nothing
	go (Just (user, pass)) = do
		e <- liftIO getEnvironment
		return $ Just $ addEntries [(uk, user), (pk, pass)] e

	creds = AWS.creds u
	(uk, pk) = credPairEnvironment creds

getVault :: RemoteConfig -> Vault
getVault = fromMaybe (error "Missing vault configuration") 
	. M.lookup "vault"

archive :: Remote -> Key -> Archive
archive r k = fileprefix ++ key2file k
  where
	fileprefix = M.findWithDefault "" "fileprefix" $ config r

genVault :: RemoteConfig -> UUID -> Annex ()
genVault c u = unlessM (runGlacier c u params) $
	error "Failed creating glacier vault."
  where
	params = 
		[ Param "vault"
		, Param "create"
		, Param $ getVault c
		]

{- Partitions the input list of keys into ones which have
 - glacier retieval jobs that have succeeded, or failed.
 -
 - A complication is that `glacier job list` will display the encrypted
 - keys when the remote is encrypted.
 -
 - Dealing with encrypted chunked keys would be tricky. However, there
 - seems to be no benefit to using chunking with glacier, so chunking is
 - not supported.
 -}
jobList :: Remote -> [Key] -> Annex ([Key], [Key])
jobList r keys = go =<< glacierEnv (config r) (uuid r)
  where
	params = [ Param "job", Param "list" ]
	nada = ([], [])
	myvault = getVault $ config r

	go Nothing = return nada
	go (Just e) = do
		v <- liftIO $ catchMaybeIO $ 
			readProcessEnv "glacier" (toCommand params) (Just e)
		maybe (return nada) extract v

	extract s = do
		let result@(succeeded, failed) =
			parse nada $ (map words . lines) s
		if result == nada
			then return nada
			else do
				enckeys <- forM keys $ \k ->
					maybe k (\(_, enck) -> enck k)
						<$> cipherKey (config r)
				let keymap = M.fromList $ zip enckeys keys
				let convert = mapMaybe (`M.lookup` keymap)
				return (convert succeeded, convert failed)

	parse c [] = c
	parse c@(succeeded, failed) ((status:_date:vault:key:[]):rest)
		| vault == myvault =
			case file2key key of
				Nothing -> parse c rest
				Just k
					| "a/d" `isPrefixOf` status ->
						parse (k:succeeded, failed) rest
					| "a/e" `isPrefixOf` status ->
						parse (succeeded, k:failed) rest
					| otherwise ->
						parse c rest
	parse c (_:rest) = parse c rest
