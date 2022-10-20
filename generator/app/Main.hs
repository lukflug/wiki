{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}
import           GHC.IO.Encoding (setLocaleEncoding, utf8)
import           Hakyll
import           System.Environment (lookupEnv)
import           Control.Applicative ((<|>))
import           Data.Maybe (fromMaybe, maybeToList)
import           Data.Char (toLower)
import           Data.List (stripPrefix)
import           Data.Time.Clock (getCurrentTime, utctDay)
import           Data.Time.Calendar (toGregorian)
import           Data.Traversable (forM)
import           Data.Yaml (decodeFileEither, prettyPrintParseException)
import qualified Data.HashMap.Strict as HM
import qualified Data.Text as T
import qualified Stork as S
import           System.Exit (die)

type Categories = HM.HashMap T.Text T.Text

adocTemplates :: String
adocTemplates = "erb"

asciidoctorOptions :: [String]
asciidoctorOptions =
    [ "-s" -- standalone page
    , "-S", "secure" -- disable potentially dangerous features
    , "-a", "source-highlighter=pygments" -- use pygments
    , "-a", "toc" -- generate TOC
    , "-a", "source-linenums-option" -- generate line numbers
    , "-a", "sectnums"
    , "-a", "showtitle"

    , "-r", "asciidoctor-bibtex"
    , "-a", "bibtex-file=sources.bib"
    , "-a", "bibtex-throw=true"
    , "-a", "bibtex-style=apa"

    , "-a", "relfileprefix=/pages/"
    , "-a", "relfilesuffix=.html" -- correctly locate xref'd pages


    , "-T", "adoc", "-E", adocTemplates
    , "-" -- stdin/stdout
    ]

itemCompiler :: Compiler (Item String)
itemCompiler = do
    ext <- getUnderlyingExtension
    if ext == ".adoc" then
        getResourceBody
            >>= loadAndApplyTemplate adocInputTemplate defaultContext
            >>= withItemBody adoctor
    else
        pandocCompiler
    where adoctor = unixFilter "asciidoctor" asciidoctorOptions
          adocInputTemplate = "adoc/adoctor_input_template.adoc"

noCategoryError :: String -> Compiler a
noCategoryError x = fail $ "Category " ++ x ++ " does not exist."

getMetadataCategory :: MonadMetadata m => Identifier -> m [String]
getMetadataCategory x = do
    maybeCategory <- getMetadataField x "category"
    let catList = (:[]) <$> maybeCategory
    return $ fromMaybe [] catList

pageCompiler :: Categories -> Compiler (Item String)
pageCompiler cs = do
    identifier <- getUnderlying
    categoryName' <- getMetadataCategory @Compiler identifier
    categoryName <- case categoryName' of
        x:[] -> return x
        _ -> fail "Failed to get category from page (is it set?)"

    if ((T.pack categoryName) `HM.member` cs) then itemCompiler
        else noCategoryError categoryName

categoryDescription :: Categories -> String -> Maybe String
categoryDescription cats cat = T.unpack <$> HM.lookup catText cats
    where catText = T.pack cat


removeField :: String -> Context String
removeField n = field n (\_ -> noResult $ "Field '"++n++"' removed.")

genericContext' :: String -> Integer -> Maybe String -> Context String
genericContext' gitHash year forge = constField "year" (show year)
    <> forgeField
    <> constField "hash" gitHash
    <> field "description" (doDescriptionField "description")
    <> field "og-description" (doDescriptionField "og-description")
    <> defaultContext
    where doDescriptionField x _ = do
            ident <- getUnderlying
            descriptionMaybe <- getMetadataField ident "description"
            titleMaybe <- getMetadataField ident "title"
            case descriptionMaybe <|> titleMaybe of
                Nothing -> noResult $ "No description provided (for " ++ x ++ ")"
                Just d -> return d
          forgeField = fromMaybe (removeField "forge")
                (fmap (constField "forge") forge)

stripIfPrefixed :: Eq a => [a] -> [a] -> [a]
stripIfPrefixed p xs = fromMaybe xs $ stripPrefix p xs

hakyllConfig :: Configuration
hakyllConfig = defaultConfiguration
    { destinationDirectory = "_site" -- hard code default
    }

main :: IO ()
main = do
    setLocaleEncoding utf8

    gitHash <- fromMaybe "main" <$> lookupEnv "GIT_HASH"
    wikiForge <- lookupEnv "WIKI_FORGE"
    (year, _, _) <- toGregorian <$> utctDay <$> getCurrentTime
    categoryFile' <- decodeFileEither @Categories "categories.yml"
    categories <- case categoryFile' of
        Left e  -> die $ prettyPrintParseException e
        Right c -> return c

    hakyllWith hakyllConfig $ do
        let genericContext = let gc = genericContext' gitHash year wikiForge in
                             openGraphField "opengraph" gc <> gc
        let pageContext path = constField "path" path <> genericContext
        let templatePath = fromGlob $ ("adoc/html5/*." ++ adocTemplates)
        adocTemplateDep <- makePatternDependency $ templatePath
        categoriesDep <- makePatternDependency "categories.yml"
        let adocExtraDeps = rulesExtraDependencies [ categoriesDep
                                                   , adocTemplateDep
                                                   ]

        -- null rule to load categories.yml into the cache
        -- the contents here don't matter since we don't use them
        -- TODO(arsen): load the category set out of hakyll rather than on
        --              startup to prevent it going out of date when using
        --              watch
        match "categories.yml" $ compile $ makeItem ()

        match "html/*" $ compile templateCompiler
        match "adoc/*.adoc" $ compile templateCompiler

        match "css/*" $ compile compressCssCompiler
        match "static/*" $ do
            route $ customRoute (\i -> "_/" ++ (toFilePath i))
            compile $ copyFileCompiler

        create ["css/pygments.css"] $
            compile $
                unixFilter "pygmentize" [ "-S", "gruvbox-dark"
                                        , "-f", "html"
                                        , "-O", "classprefix=tok-"
                                        ] "" >>= makeItem

        create ["_/stylesheet.css"] $ do
            route idRoute
            compile $ do
                sheets <- loadAll "css/*"
                makeItem $ unlines $ map itemBody sheets

        match "licenses/*" $ do
            route idRoute
            compile $ copyFileCompiler

        let pageHandler compiler = do
                route $ setExtension "html"
                compile $ do
                    path' <- getResourceFilePath
                    let path = stripIfPrefixed "./" path'
                    let ctx = pageContext path
                    getResourceBody
                        >>= saveSnapshot "source" -- needed for indexes
                        >>  compiler
                        >>= loadAndApplyTemplate "html/wrapper.html" ctx
                        >>= relativizeUrls

        adocExtraDeps $ match "pages/*.adoc" $ pageHandler $ pageCompiler categories
        adocExtraDeps $ match "index.adoc" $ pageHandler $ itemCompiler

        -- index pages with stork
        create ["searchidx.st"] $ do
            route idRoute
            compile $ loadAll "pages/*"
                >>= (S.render $ destinationDirectory hakyllConfig)

        tags <- buildTags "pages/*" (fromCapture "tags/*.html")
        cats <- let fromLowCapture pat x = fromCapture pat (map toLower x) in
                    buildTagsWith getMetadataCategory "pages/*"
                    (fromLowCapture "categories/*.html")

        let tagIdxPage = \titlePfx fdesc tag pattern -> do
                route idRoute
                let title = concat [titlePfx," \"",tag,"\""]
                let descriptionMaybe = constField "tagDescription" <$> fdesc tag
                compile $ do
                    pages <- loadAllSnapshots pattern "source"
                    let idxContext = mconcat $
                            [ constField "title" title
                            , constField "description" title
                            , listField "pages" genericContext $ return pages
                            , removeField "forge"
                            , genericContext
                            ] ++ (maybeToList $ descriptionMaybe)
                    makeItem ""
                        >>= loadAndApplyTemplate "html/tag_index.html" idxContext
                        >>= loadAndApplyTemplate "html/wrapper.html" idxContext
                        >>= relativizeUrls

        tagsRules tags $ tagIdxPage "Pages tagged with" (const Nothing)
        tagsRules cats $ tagIdxPage "Pages categorized under" $
                categoryDescription categories

        -- TODO(arsen): provide better context for templates to use
        let renderTagPage = \title tagList -> do
                route idRoute
                compile $ do
                    let listContext = mconcat
                            [ constField "title" title
                            , constField "description" title
                            , tagsField "tags" tagList
                            , removeField "forge"
                            , genericContext
                            ]
                    renderredList <- renderTagList tagList
                    makeItem renderredList
                            >>= loadAndApplyTemplate "html/tag_list.html" listContext
                            >>= loadAndApplyTemplate "html/wrapper.html" listContext
                            >>= relativizeUrls

        create ["tags/index.html"] $ renderTagPage "Global tag list" tags
        create ["categories/index.html"] $ renderTagPage "Global category list" cats

        let errorPageIdentifier = fromFilePath . (++".html") . show
        forM [(404 :: Int, "Not Found")] $
            \(code', msg) -> create [errorPageIdentifier code'] $ do
                let code = show code'
                route idRoute
                let title = code ++ " " ++ msg
                let errorContext = mconcat
                        [ constField "title" title
                        , constField "description" title
                        , constField "error" code
                        , constField "errormsg" msg
                        , removeField "forge"
                        , genericContext
                        ]
                compile $ makeItem ""
                    >>= loadAndApplyTemplate "html/error_page.html" errorContext
                    >>= loadAndApplyTemplate "html/wrapper.html" errorContext
                    >>= relativizeUrls
