{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings          #-}

module Package.C.PackageSet ( PackageSet (..)
                            , PackId
                            , pkgsM
                            , displayPackageSet
                            ) where

import           Algebra.Graph.AdjacencyMap            (edges)
import           Algebra.Graph.AdjacencyMap.Algorithm  (topSort)
import           CPkgPrelude
import           Data.Containers.ListUtils
import           Data.List                             (intersperse)
import qualified Data.Map                              as M
import qualified Data.Text                             as T
import           Data.Text.Prettyprint.Doc
import           Data.Text.Prettyprint.Doc.Custom
import           Data.Text.Prettyprint.Doc.Render.Text
import           Data.Tree                             (Tree (..))
import           Dhall
import qualified Package.C.Dhall.Type                  as Dhall
import           Package.C.Error
import           Package.C.Type

defaultPackageSetDhall :: Maybe String -> IO PackageSetDhall
defaultPackageSetDhall (Just pkSet) = input auto (T.pack pkSet)
defaultPackageSetDhall Nothing      = input auto "https://raw.githubusercontent.com/vmchale/cpkg/master/pkgs/pkg-set.dhall"

displayPackageSet :: Maybe String -> IO ()
displayPackageSet = putDoc . pretty <=< defaultPackageSetDhall

newtype PackageSetDhall = PackageSetDhall [ Dhall.CPkg ]
    deriving Interpret

instance Pretty PackageSetDhall where
    pretty (PackageSetDhall set) = vdisplay (intersperse hardline (pretty <$> set)) <> hardline

newtype PackageSet = PackageSet (M.Map T.Text CPkg)

type PackId = T.Text

packageSetDhallToPackageSet :: PackageSetDhall -> PackageSet
packageSetDhallToPackageSet (PackageSetDhall pkgs'') =
    let names = Dhall.pkgName <$> pkgs''
        pkgs' = cPkgDhallToCPkg <$> pkgs''

        in PackageSet $ M.fromList (zip names pkgs')

-- TODO: a graph-like structure that has two distinct types of edges?
-- we need to separate build depends &c.
getDeps :: PackId -> PackageSet -> Maybe [(PackId, PackId)]
getDeps pkgName' set@(PackageSet ps) = do
    cpkg <- M.lookup pkgName' ps
    let depNames = (name <$> pkgDeps cpkg) ++ (name <$> pkgBuildDeps cpkg)
    case nubOrd depNames of
        [] -> pure []
        xs -> do
            transitive <- fold <$> traverse (\p -> getDeps p set) xs
            let self = zip (repeat pkgName') xs
            pure (transitive ++ self)

splitTree :: [PackId] -> PackageSet -> Maybe (Tree PackId)
splitTree [] _        = Nothing
splitTree [p] _       = Just (Node p [])
splitTree (p:ps) pset = Node p . pure <$> splitTree ps pset

-- TODO: use dfsForest but check for cycles
pkgPlan :: PackId -> PackageSet -> Maybe (Tree PackId)
pkgPlan pkId ps = do
    ds <- getDeps pkId ps
    sorted <- topSort (edges ds)
    case sorted of
        []  -> pure (Node pkId [])
        ds' -> splitTree sorted ps

pkgs :: PackId -> PackageSet -> Maybe (Tree CPkg)
pkgs pkId set@(PackageSet pset) = do
    plan <- pkgPlan pkId set
    traverse (`M.lookup` pset) plan

pkgsM :: PackId -> Maybe String -> IO (Tree CPkg)
pkgsM pkId pkSet = do
    pks <- pkgs pkId . packageSetDhallToPackageSet <$> defaultPackageSetDhall pkSet
    case pks of
        Just x  -> pure x
        Nothing -> unfoundPackage
