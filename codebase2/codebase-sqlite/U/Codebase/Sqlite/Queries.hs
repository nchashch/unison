{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TemplateHaskell #-}

module U.Codebase.Sqlite.Queries where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Reader (MonadReader (ask))
import Data.ByteString (ByteString)
import Control.Monad.Trans (MonadIO (liftIO))
import Data.Maybe (fromJust)
import Data.String.Here.Uninterpolated (here)
import Data.Text (Text)
import qualified Database.SQLite.Simple as SQLite
import Database.SQLite.Simple (SQLData, (:.) (..), Connection, FromRow, Only (..), ToRow (..))
import Database.SQLite.Simple.FromField ( FromField )
import Database.SQLite.Simple.ToField ( ToField )
import qualified U.Codebase.Sqlite.Reference as Reference
import qualified U.Codebase.Sqlite.Referent as Referent
import U.Codebase.Sqlite.ObjectType ( ObjectType )
import U.Util.Base32Hex (Base32Hex (..))
import U.Util.Hashable (Hashable)
import U.Util.Hash (Hash)
import qualified U.Util.Hash as Hash
import U.Codebase.Sqlite.DbId ( HashId(..), ObjectId(..), TextId )
import U.Codebase.Reference (Reference')

-- * types
type DB m = (MonadIO m, MonadReader Connection m)

newtype TypeId = TypeId ObjectId deriving (FromField, ToField) via ObjectId
newtype TermId = TermCycleId ObjectId deriving (FromField, ToField) via ObjectId
newtype DeclId = DeclCycleId ObjectId deriving (FromField, ToField) via ObjectId
newtype CausalHashId = CausalHashId HashId deriving (Hashable, FromField, ToField) via HashId
newtype CausalOldHashId = CausalOldHashId HashId deriving (Hashable, FromField, ToField) via HashId
newtype NamespaceHashId = NamespaceHashId ObjectId deriving (Hashable, FromField, ToField) via ObjectId

-- type DerivedReferent = Referent.Id ObjectId ObjectId
-- type DerivedReference = Reference.Id ObjectId
type TypeHashReference = Reference' TextId HashId

-- * main squeeze

saveHash :: DB m => Base32Hex -> m HashId
saveHash base32 = execute sql (Only base32) >> queryOne (loadHashId base32)
  where sql = [here| INSERT OR IGNORE INTO hash (base32) VALUES (?) |]

saveHashHash :: DB m => Hash -> m HashId
saveHashHash = saveHash . Hash.toBase32Hex

loadHashId :: DB m => Base32Hex -> m (Maybe HashId)
loadHashId base32 = queryOnly sql (Only base32)
  where sql = [here| SELECT id FROM hash WHERE base32 = ? |]

loadHashById :: DB m => HashId -> m (Maybe Base32Hex)
loadHashById h = queryOnly sql (Only h)
  where sql = [here| SELECT base32 FROM hash WHERE id = ? |]

saveText :: DB m => Text -> m TextId
saveText t = execute sql (Only t) >> queryOne (loadText t)
  where sql = [here| INSERT OR IGNORE INTO text (text) VALUES (?) |]

loadText :: DB m => Text -> m (Maybe TextId)
loadText t = queryOnly sql (Only t)
  where sql = [here| SELECT id FROM text WHERE text = ? |]

loadTextById :: DB m => TextId -> m (Maybe Text)
loadTextById h = queryOnly sql (Only h)
  where sql = [here| SELECT text FROM text WHERE id = ? |]

saveHashObject :: DB m => HashId -> ObjectId -> Int -> m ()
saveHashObject hId oId version = execute sql (hId, oId, version) where
  sql = [here|
    INSERT OR IGNORE INTO hash_object (hash_id, object_id, version)
    VALUES (?, ?, ?)
  |]

saveObject :: DB m => HashId -> ObjectType -> ByteString -> m ObjectId
saveObject h t blob =
  execute sql (h, t, blob) >> queryOne (objectIdByPrimaryHashId h)
  where
  sql = [here|
    INSERT OR IGNORE INTO object (primary_hash_id, type_id, bytes)
    VALUES (?, ?, ?)
  |]

loadObjectById :: DB m => ObjectId -> m (Maybe ByteString)
loadObjectById oId = queryOnly sql (Only oId) where sql = [here|
  SELECT bytes FROM object WHERE id = ?
|]

objectIdByPrimaryHashId :: DB m => HashId -> m (Maybe ObjectId)
objectIdByPrimaryHashId h = queryOnly sql (Only h) where sql = [here|
  SELECT id FROM object WHERE primary_hash_id = ?
|]

objectIdByAnyHash :: DB m => Base32Hex -> m (Maybe ObjectId)
objectIdByAnyHash h = queryOnly sql (Only h) where sql = [here|
  SELECT object.id
  FROM hash
  INNER JOIN hash_object ON hash_object.hash_id = hash.id
  INNER JOIN object ON hash_object.object_id = object.id
  WHERE hash.base32 = ?
|]

loadPrimaryHashByObjectId :: DB m => ObjectId -> m (Maybe Base32Hex)
loadPrimaryHashByObjectId oId = queryOnly sql (Only oId) where sql = [here|
  SELECT hash.base32
  FROM hash INNER JOIN hash_object ON hash_object.hash_id = hash.id
  WHERE hash_object.object_id = ?
|]

objectAndPrimaryHashByAnyHash :: DB m => Base32Hex -> m (Maybe (Base32Hex, ObjectId))
objectAndPrimaryHashByAnyHash h = queryMaybe sql (Only h) where sql = [here|
  SELECT object.primary_hash_id, object.id
  FROM hash
  INNER JOIN hash_object ON hash_object.hash_id = hash.id
  INNER JOIN object ON hash_object.objectId = object.id
  WHERE hash.base32 = ?
|]

objectExistsWithHash :: DB m => Base32Hex -> m Bool
objectExistsWithHash h = queryExists sql (Only h) where
  sql = [here|
    SELECT 1
    FROM hash INNER JOIN hash_object ON hash.id = hash_object.hash_id
    WHERE base32 = ?
  |]

updateObjectBlob :: DB m => ObjectId -> ByteString -> m ()
updateObjectBlob oId bs = execute sql (oId, bs) where sql = [here|
  UPDATE object SET bytes = ? WHERE id = ?
|]

-- |Maybe we would generalize this to something other than NamespaceHash if we
-- end up wanting to store other kinds of Causals here too.
saveCausal :: DB m => CausalHashId -> NamespaceHashId -> m ()
saveCausal self value = execute sql (self, value) where sql = [here|
  INSERT OR IGNORE INTO causal (self_hash_id, value_hash_id) VALUES (?, ?)
|]

loadCausalValueHash :: DB m => CausalHashId -> m (Maybe NamespaceHashId)
loadCausalValueHash hash = queryOnly sql (Only hash) where sql = [here|
  SELECT value_hash_id FROM causal WHERE self_hash_id = ?
|]

saveCausalOld :: DB m => HashId -> CausalHashId -> m ()
saveCausalOld v1 v2 = execute sql (v1, v2) where sql = [here|
  INSERT OR IGNORE INTO causal_old (old_hash_id, new_hash_id) VALUES (?, ?)
|]

loadCausalHashIdByCausalOldHash :: DB m => CausalOldHashId -> m (Maybe CausalHashId)
loadCausalHashIdByCausalOldHash id = queryOnly sql (Only id) where sql = [here|
  SELECT new_hash_id FROM causal_old where old_hash_id = ?
|]

loadOldCausalValueHash :: DB m => CausalOldHashId -> m (Maybe NamespaceHashId)
loadOldCausalValueHash id = queryOnly sql (Only id) where sql = [here|
  SELECT value_hash_id FROM causal
  INNER JOIN causal_old ON self_hash_id = new_hash_id
  WHERE old_hash_id = ?
|]

saveCausalParent :: DB m => CausalHashId -> CausalHashId -> m ()
saveCausalParent child parent = execute sql (child, parent) where
  sql = [here|
    INSERT OR IGNORE INTO causal_parent (causal_id, parent_id) VALUES (?, ?)
  |]

loadCausalParents :: DB m => CausalHashId -> m [CausalHashId]
loadCausalParents h = queryList sql (Only h) where sql = [here|
  SELECT parent_id FROM causal_parent WHERE causal_id = ?
|]

saveTypeOfTerm :: DB m => Reference.Id -> ByteString -> m ()
saveTypeOfTerm r blob = execute sql (r :. Only blob) where sql = [here|
    INSERT OR IGNORE INTO type_of_term
    VALUES (?, ?, ?)
  |]

loadTypeOfTerm :: DB m => Reference.Id -> m (Maybe ByteString)
loadTypeOfTerm r = queryOnly sql r where sql = [here|
  SELECT bytes FROM type_of_term
  WHERE object_id = ? AND component_index = ?
|]

-- * Index-building
addToTypeIndex :: DB m => Reference' TextId HashId -> Referent.Id -> m ()
addToTypeIndex tp tm = execute sql (tp :. tm) where sql = [here|
  INSERT OR IGNORE INTO find_type_index (
    type_reference_builtin,
    type_reference_hash_id,
    type_reference_component_index,
    term_referent_object_id,
    term_referent_component_index,
    term_referent_constructor_index
  ) VALUES (?, ?, ?, ?, ?, ?)
|]

addToTypeMentionsIndex :: DB m => Reference' TextId HashId -> Referent.Id -> m ()
addToTypeMentionsIndex tp tm = execute sql (tp :. tm) where sql = [here|
  INSERT OR IGNORE INTO find_type_mentions_index (
    type_reference_builtin,
    type_reference_hash_id,
    type_reference_component_index,
    term_referent_object_id,
    term_referent_component_index,
    term_referent_constructor_index
  ) VALUES (?, ?, ?, ?, ?, ?)
|]

addToDependentsIndex :: DB m => Reference.Reference -> Reference.Id -> m ()
addToDependentsIndex dependency dependent = execute sql (dependency :. dependent)
  where sql = [here|
    INSERT OR IGNORE INTO dependents_index (
      dependency_builtin,
      dependency_object_id,
      dependency_component_index,
      dependent_object_id,
      dependent_component_index
    ) VALUES (?, ?, ?, ?, ?)
  |]

getDependentsForDependency :: DB m => Reference.Reference -> m [Reference.Id]
getDependentsForDependency dependency = query sql dependency where sql = [here|
  SELECT dependent_object_id, dependent_component_index
  FROM dependents_index
  WHERE dependency_builtin = ?
    AND dependency_object_id = ?
    AND dependency_component_index = ?
|]

objectIdByBase32Prefix :: DB m => ObjectType -> Text -> m [ObjectId]
objectIdByBase32Prefix objType prefix = queryList sql (objType, prefix <> "%") where sql = [here|
  SELECT object.id FROM object
  INNER JOIN hash_object ON hash_object.object_id = object.id
  INNER JOIN hash ON hash_object.hash_id = hash.id
  WHERE object.type_id = ?
    AND hash.base32 LIKE ?
|]
-- alternatively
-- [here|
--   SELECT object.id
--   FROM object, hash, hash_object
--   WHERE object.id = hash_object.object_id
--     AND hash.id = hash_object.hash_id
--     AND object.type_id = ?
--     AND hash.base32 LIKE ?
-- |]

-- * helper functions
queryList :: (DB f, ToRow q, FromField b) => SQLite.Query -> q -> f [b]
queryList q r = map fromOnly <$> query q r
queryMaybe :: (DB f, ToRow q, FromRow b) => SQLite.Query -> q -> f (Maybe b)
queryMaybe q r = headMay <$> query q r

queryOnly :: (DB f, ToRow q, FromField b) => SQLite.Query -> q -> f (Maybe b)
queryOnly q r = fmap fromOnly <$> queryMaybe q r

queryOne :: Functor f => f (Maybe b) -> f b
queryOne = fmap fromJust

queryExists :: (DB m, ToRow q) => SQLite.Query -> q -> m Bool
queryExists q r = not . null . map (id @SQLData) <$> queryList q r

query :: (DB m, ToRow q, SQLite.FromRow r) => SQLite.Query -> q -> m [r]
query q r = do c <- ask; liftIO $ SQLite.query c q r
execute :: (DB m, ToRow q) => SQLite.Query -> q -> m ()
execute q r = do c <- ask; liftIO $ SQLite.execute c q r

headMay :: [a] -> Maybe a
headMay [] = Nothing
headMay (a:_) = Just a

-- * orphan instances
deriving via Text instance ToField Base32Hex
deriving via Text instance FromField Base32Hex