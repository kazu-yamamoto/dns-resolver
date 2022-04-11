module DNSC.UpdateCache (
  newCache,
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Chan (newChan, readChan, writeChan)
import Control.Monad (void, forever)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Time (UTCTime, getCurrentTime)

import Network.DNS (TTL, Domain, TYPE, CLASS, ResourceRecord)

import DNSC.Cache (Cache, Key, Val, CRSet, Ranking)
import qualified DNSC.Cache as Cache

data Update
  = I Key TTL CRSet Ranking
  | E
  deriving Show

runUpdate :: UTCTime -> Update -> Cache -> Maybe Cache
runUpdate t u = case u of
  I k ttl crs rank -> Cache.insert t k ttl crs rank
  E                -> Cache.expires t

type Lookup = Domain -> TYPE -> CLASS -> IO (Maybe ([ResourceRecord], Ranking))
type Insert = Key -> TTL -> CRSet -> Ranking -> IO ()
type Dump = IO [(Key, (UTCTime, Val))]

newCache :: (String -> IO ()) -> IO (Lookup, Insert, Dump)
newCache putLog = do
  let putLn = putLog . (++ "\n")
  cacheRef <- newIORef Cache.empty
  updateQ <- newChan

  let update1 = do   -- step of single update theard
        (ts, u) <- readChan updateQ
        cache <- readIORef cacheRef
        let updateRef c = do
              writeIORef cacheRef c
              case u of
                I {}  ->  return ()
                E     ->  putLn $ show ts ++ ": some records expired: size = " ++ show (Cache.size c)
        maybe (pure ()) updateRef $ runUpdate ts u cache
  void $ forkIO $ forever update1

  let expires1 = do
        threadDelay $ 1000 * 1000
        writeChan updateQ =<< (,) <$> getCurrentTime <*> pure E
  void $ forkIO $ forever expires1

  let lookup_ dom typ cls = do
        cache <- readIORef cacheRef
        ts <- getCurrentTime
        return $ Cache.lookup ts dom typ cls cache

      insert k ttl crs rank =
        writeChan updateQ =<< (,) <$> getCurrentTime <*> pure (I k ttl crs rank)

      dump = do
        cache <- readIORef cacheRef
        return $ Cache.dump cache

  return (lookup_, insert, dump)
