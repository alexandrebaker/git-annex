{- git-annex assistant webapp configurators for WebDAV remotes
 -
 - Copyright 2012, 2013 Joey Hess <joey@kitenet.net>
 -
 - Licensed under the GNU AGPL version 3 or higher.
 -}

{-# LANGUAGE CPP, TypeFamilies, QuasiQuotes, MultiParamTypeClasses, TemplateHaskell, OverloadedStrings, RankNTypes #-}

module Assistant.WebApp.Configurators.WebDAV where

import Assistant.WebApp.Common
import Creds
#ifdef WITH_WEBDAV
import qualified Remote.WebDAV as WebDAV
import Assistant.MakeRemote
import Assistant.Sync
import qualified Remote
import Types.Remote (RemoteConfig)
import Types.StandardGroups
import Logs.PreferredContent
import Logs.Remote

import qualified Data.Map as M
#endif
import qualified Data.Text as T
import Network.URI

webDAVConfigurator :: Widget -> Handler RepHtml
webDAVConfigurator = page "Add a WebDAV repository" (Just Configuration)

boxConfigurator :: Widget -> Handler RepHtml
boxConfigurator = page "Add a Box.com repository" (Just Configuration)

data WebDAVInput = WebDAVInput
	{ user :: Text
	, password :: Text
	, embedCreds :: Bool
	, directory :: Text
	, enableEncryption :: EnableEncryption
	}

toCredPair :: WebDAVInput -> CredPair
toCredPair input = (T.unpack $ user input, T.unpack $ password input)

boxComAForm :: Maybe CredPair -> AForm WebApp WebApp WebDAVInput
boxComAForm defcreds = WebDAVInput
	<$> areq textField "Username or Email" (T.pack . fst <$> defcreds)
	<*> areq passwordField "Box.com Password" (T.pack . snd <$> defcreds)
	<*> areq checkBoxField "Share this account with other devices and friends?" (Just True)
	<*> areq textField "Directory" (Just "annex")
	<*> enableEncryptionField

webDAVCredsAForm :: Maybe CredPair -> AForm WebApp WebApp WebDAVInput
webDAVCredsAForm defcreds = WebDAVInput
	<$> areq textField "Username or Email" (T.pack . fst <$> defcreds)
	<*> areq passwordField "Password" (T.pack . snd <$> defcreds)
	<*> pure False
	<*> pure T.empty
	<*> pure NoEncryption -- not used!

getAddBoxComR :: Handler RepHtml
getAddBoxComR = postAddBoxComR
postAddBoxComR :: Handler RepHtml
#ifdef WITH_WEBDAV
postAddBoxComR = boxConfigurator $ do
	defcreds <- liftAnnex $ previouslyUsedWebDAVCreds "box.com"
	((result, form), enctype) <- lift $
		runFormPost $ renderBootstrap $ boxComAForm defcreds
	case result of
		FormSuccess input -> lift $ 
			makeWebDavRemote "box.com" (toCredPair input) setgroup $ M.fromList
				[ configureEncryption $ enableEncryption input
				, ("embedcreds", if embedCreds input then "yes" else "no")
				, ("type", "webdav")
				, ("url", "https://www.box.com/dav/" ++ T.unpack (directory input))
				-- Box.com has a max file size of 100 mb, but
				-- using smaller chunks has better memory
				-- performance.
				, ("chunksize", "10mb")
				]
		_ -> $(widgetFile "configurators/addbox.com")
  where
	setgroup r = liftAnnex $
		setStandardGroup (Remote.uuid r) TransferGroup
#else
postAddBoxComR = error "WebDAV not supported by this build"
#endif

getEnableWebDAVR :: UUID -> Handler RepHtml
getEnableWebDAVR = postEnableWebDAVR
postEnableWebDAVR :: UUID -> Handler RepHtml
#ifdef WITH_WEBDAV
postEnableWebDAVR uuid = do
	m <- liftAnnex readRemoteLog
	let c = fromJust $ M.lookup uuid m
	let name = fromJust $ M.lookup "name" c
	let url = fromJust $ M.lookup "url" c
	mcreds <- liftAnnex $
		getRemoteCredPairFor "webdav" c (WebDAV.davCreds uuid)
	case mcreds of
		Just creds -> webDAVConfigurator $ lift $
			makeWebDavRemote name creds (const noop) M.empty
		Nothing
			| "box.com/" `isInfixOf` url ->
				boxConfigurator $ showform name url
			| otherwise ->
				webDAVConfigurator $ showform name url
  where
	showform name url = do
		defcreds <- liftAnnex $ 
			maybe (pure Nothing) previouslyUsedWebDAVCreds $
				urlHost url
		((result, form), enctype) <- lift $
			runFormPost $ renderBootstrap $ webDAVCredsAForm defcreds
		case result of
			FormSuccess input -> lift $
				makeWebDavRemote name (toCredPair input) (const noop) M.empty
			_ -> do
				description <- liftAnnex $
					T.pack <$> Remote.prettyUUID uuid
				$(widgetFile "configurators/enablewebdav")
#else
postEnableWebDAVR _ = error "WebDAV not supported by this build"
#endif

#ifdef WITH_WEBDAV
makeWebDavRemote :: String -> CredPair -> (Remote -> Handler ()) -> RemoteConfig -> Handler ()
makeWebDavRemote name creds setup config = do
	remotename <- liftAnnex $ fromRepo $ uniqueRemoteName name 0
	liftIO $ WebDAV.setCredsEnv creds
	r <- liftAnnex $ addRemote $ do
		makeSpecialRemote name WebDAV.remote config
		return remotename
	setup r
	liftAssistant $ syncRemote r
	redirect $ EditNewCloudRepositoryR $ Remote.uuid r

{- Only returns creds previously used for the same hostname. -}
previouslyUsedWebDAVCreds :: String -> Annex (Maybe CredPair)
previouslyUsedWebDAVCreds hostname =
	previouslyUsedCredPair WebDAV.davCreds WebDAV.remote samehost
  where
	samehost url = case urlHost =<< WebDAV.configUrl url of
		Nothing -> False
		Just h -> h == hostname
#endif

urlHost :: String -> Maybe String
urlHost url = uriRegName <$> (uriAuthority =<< parseURI url)
