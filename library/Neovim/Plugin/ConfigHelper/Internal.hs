{-# LANGUAGE RecordWildCards #-}
{- |
Module      :  Neovim.Plugin.ConfigHelper.Internal
Description :  Internals for a config helper plugin that helps recompiling nvim-hs
Copyright   :  (c) Sebastian Witte
License     :  Apache-2.0

Maintainer  :  woozletoff@gmail.com
Stability   :  experimental
Portability :  GHC

-}
module Neovim.Plugin.ConfigHelper.Internal
    where

import           Neovim.API.String       (vim_command)
import           Neovim.Config
import           Neovim.Context
import           Neovim.Plugin.Classes
import           Neovim.Quickfix
import           Neovim.Util             (withCustomEnvironment)

import           Neovim.Compat.Megaparsec as P hiding (count)

import           Config.Dyre             (Params)
import           Config.Dyre.Compile
import           Config.Dyre.Paths       (getPaths)
import           Control.Applicative     hiding ((<|>))
import           Control.Monad           (void, forM_)
import           Data.Char
import           System.SetEnv
import           System.Directory        (removeDirectoryRecursive)
import           UnliftIO.STM

import           Prelude


-- | Simple function that will return @"Pong"@ if the plugin provider is
-- running.
pingNvimhs :: Neovim env String
pingNvimhs = return "Pong"

data ConfigHelperEnv = ConfigHelperEnv
    { dyreParameters       :: Params NeovimConfig
    , environmentVariables :: [(String, Maybe String)]
    , quickfixList         :: TVar [QuickfixListItem String]
    }

-- | Recompile the plugin provider and put comile errors in the quickfix list.
recompileNvimhs :: Neovim ConfigHelperEnv ()
recompileNvimhs = ask >>= \ConfigHelperEnv{..} ->
    withCustomEnvironment environmentVariables $ do
        mErrString <- liftIO $ do
            customCompile dyreParameters
            getErrorString dyreParameters
        let qs = maybe [] parseQuickfixItems mErrString
        atomically $ modifyTVar' quickfixList (const qs)
        setqflist qs Replace
        void $ vim_command "cwindow"


-- | Note that restarting the plugin provider implies compilation because Dyre
-- does this automatically. However, if the recompilation fails, the previously
-- compiled binary is executed. This essentially means that restarting may take
-- more time then you might expect.
--
-- If you provide a bang to the command, the cache directory of /nvim-hs/ is
-- forcibly removed.
restartNvimhs :: CommandArguments
              -> Neovim ConfigHelperEnv ()
restartNvimhs CommandArguments{..} = do
    case bang of
        Just True -> do
            (_,_,_, cacheDir,_) <- liftIO . getPaths =<< asks dyreParameters
            liftIO $ removeDirectoryRecursive cacheDir

        _ ->
            return ()

    recompileNvimhs

    envVars <- asks environmentVariables
    forM_ envVars $ \(var, val) -> liftIO $ maybe (unsetEnv var) (setEnv var) val
    restart

-- Parsing {{{1
-- See the tests in @test-suite\/Neovim\/Plugin\/ConfigHelperSpec.hs@ on how the
-- error messages look like.
parseQuickfixItems :: String -> [QuickfixListItem String]
parseQuickfixItems s =
    case parse (P.many pQuickfixListItem) "Quickfix parser" s of
        Right qs -> qs
        Left _   -> []


pQuickfixListItem :: P.Parser (QuickfixListItem String)
pQuickfixListItem = do
    _ <- P.many blankLine
    (f,l,c) <- pLocation

    void $ P.many tabOrSpace
    e <- pSeverity
    desc <- try pShortDesrciption <|> pLongDescription
    return $ (quickfixListItem (Right f) (Left l))
        { col = VisualColumn c
        , text = desc
        , errorType = e
        }

pSeverity :: P.Parser QuickfixErrorType
pSeverity = do
    try (string "Warning:" *> return Warning)
    <|> try (string "error:"   *> return Error)
    <|> return Error

pShortDesrciption :: P.Parser String
pShortDesrciption = (:)
    <$> (notFollowedBy blankLine *> anyChar)
    <*> anyChar `manyTill` (void (P.some blankLine) <|> eof)


pLongDescription :: P.Parser String
pLongDescription = anyChar `manyTill` (blank <|> eof)
  where
    blank = try (try newline *> try blankLine)


tabOrSpace :: P.Parser Char
tabOrSpace = satisfy $ \c -> c == ' ' || c == '\t'


blankLine :: P.Parser ()
blankLine = void . try $ P.many tabOrSpace >> newline


-- | Skip anything until the next location information appears.
--
-- The result will be a triple of filename, line number and column

-- | Try to parse location information.
--
-- @\/some\/path\/to\/a\/file.hs:42:88:@
pLocation :: P.Parser (String, Int, Int)
pLocation = (,,)
    <$> P.some (noneOf (":\n\t\r" :: [Char])) <* char ':'
    <*> pInt <* char ':'
    <*> pInt <* char ':' <* P.many tabOrSpace


pInt :: P.Parser Int
pInt = read <$> P.some (satisfy isDigit)
-- 1}}}
