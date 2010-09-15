{-# LANGUAGE RankNTypes, ExistentialQuantification, FlexibleContexts, ScopedTypeVariables, TypeFamilies, TypeSynonymInstances, FlexibleInstances #-}
module Language.KansasLava.Testing.Trace (Trace(..), Run(..), setCycles
                                         ,addInput, getInput, remInput
                                         ,setOutput, getOutput, clearOutput
                                         ,addProbe, getProbe, remProbe
                                         ,toXStream, fromXStream -- needed in Probes, but should not be re-exported to user
                                         ,diff, emptyTrace, takeTrace, dropTrace
                                         ,serialize, deserialize, genShallow, genInfo
                                         ,writeToFile, readFromFile, checkExpected, execute) where

import Language.KansasLava.Types
import Language.KansasLava.Wire
import Language.KansasLava.Utils
import Language.KansasLava.Seq
import Language.KansasLava.Comb
import Language.KansasLava.Signal

import qualified Language.KansasLava.Stream as Stream
import Language.KansasLava.Stream (Stream)
import Language.KansasLava.Testing.Utils

import qualified Data.Sized.Matrix as Matrix

import Data.List
import qualified Data.Map as M
import Data.Maybe

import Debug.Trace

type TraceMap k = M.Map k TraceStream

-- instance Functor TraceStream where -- can we do this with proper types?

data Trace = Trace { len :: Maybe Int
                   , inputs :: TraceMap OVar
                   , outputs :: TraceStream
                   , probes :: TraceMap OVar
                   , signature :: Signature
--                   , opts :: DebugOpts -- can see a case for this eventually
                   }
-- Combinators to change a trace
setCycles :: Int -> Trace -> Trace
setCycles i t = t { len = Just i }

addInput :: forall a. (Rep a) => OVar -> Seq a -> Trace -> Trace
addInput key seq t@(Trace _ ins _ _ _) = t { inputs = addSeq key seq ins }

getInput :: (Rep w) => OVar -> w -> Trace -> Seq w
getInput key witness trace = getSeq key (inputs trace) witness

remInput :: OVar -> Trace -> Trace
remInput key t@(Trace _ ins _ _ _) = t { inputs = M.delete key ins }

setOutput :: forall a. (Rep a) => Seq a -> Trace -> Trace
setOutput (Seq s _) t = t { outputs = fromXStream (witness :: a) s }

getOutput :: (Rep w) => w -> Trace -> Seq w
getOutput witness trace = shallowSeq $ toXStream witness $ outputs trace

clearOutput :: Trace -> Trace
clearOutput t = t { outputs = Empty }

addProbe :: forall a. (Rep a) => OVar -> Seq a -> Trace -> Trace
addProbe key seq t@(Trace _ _ _ ps _) = t { probes = addSeq key seq ps }

getProbe :: (Rep w) => OVar -> w -> Trace -> Seq w
getProbe key witness trace = getSeq key (probes trace) witness

remProbe :: OVar -> Trace -> Trace
remProbe key t@(Trace _ _ _ ps _) = t { probes = M.delete key ps }

-- instances for Trace
instance Show Trace where
    show (Trace c i (TraceStream oty os) p sig) = unlines $ concat [[show sig,show c,"inputs"], printer i, ["outputs", show (oty,takeMaybe c os), "probes"], printer p]
        where printer m = [show (k,TraceStream ty $ takeMaybe c val) | (k,TraceStream ty val) <- M.toList m]

-- two traces are equal if they have the same length and all the streams are equal over that length
instance Eq Trace where
    (==) (Trace c1 i1 (TraceStream oty1 os1) p1 sig1) (Trace c2 i2 (TraceStream oty2 os2) p2 sig2) = (sig1 == sig2) && (c1 == c2) && insEqual && outEqual && probesEqual
        where sorted m = [(k,TraceStream ty $ takeMaybe c1 s) | (k,TraceStream ty s) <- M.assocs m]
              insEqual = (sorted i1) == (sorted i2)
              outEqual = (oty1 == oty2) && (takeMaybe c1 os1 == takeMaybe c2 os2)
              probesEqual = (sorted p1) == (sorted p2)

-- something more intelligent someday?
diff :: Trace -> Trace -> Bool
diff t1 t2 = t1 == t2

emptyTrace :: Trace
emptyTrace = Trace { len = Nothing, inputs = M.empty, outputs = Empty, probes = M.empty, signature = Signature [] [] [] }

takeTrace :: Int -> Trace -> Trace
takeTrace i t = t { len = Just newLen }
    where newLen = case len t of
                    Just x -> min i x
                    Nothing -> i

dropTrace :: Int -> Trace -> Trace
dropTrace i t@(Trace c ins (TraceStream oty os) ps _)
    | newLen > 0 = t { len = Just newLen
                     , inputs = dropStream ins
                     , outputs = TraceStream oty $ drop i os
                     , probes = dropStream ps }
    | otherwise = emptyTrace
    where dropStream m = M.fromList [ (k,TraceStream ty (drop i s)) | (k,TraceStream ty s) <- M.toList m ]
          newLen = maybe i (\x -> x - i) c

-- need to change format to be vertical
serialize :: Trace -> String
serialize (Trace c ins (TraceStream oty os) ps sig) = concat $
			unlines [show sig, show c, "INPUTS"] : showMap ins ++
			[unlines ["OUTPUT", show $ OVar 0 "placeholder", show oty, showStrm os, "PROBES"]] ++
			showMap ps
    where showMap m = [unlines [show k, show ty, showStrm strm] | (k,TraceStream ty strm) <- M.toList m]
          showStrm s = unwords [concatMap (showRep (witness :: Bool)) $ val | RepValue val <- takeMaybe c s]

deserialize :: String -> Trace
deserialize str = Trace { len = c, inputs = ins, outputs = out, probes = ps, signature = s }
    where (sig:cstr:"INPUTS":ls) = lines str
          c = read cstr :: Maybe Int
          s = read sig :: Signature
          (ins,"OUTPUT":r1) = readMap ls
          (out,"PROBES":r2) = readStrm r1
          (ps,_) = readMap r2

genShallow :: Trace -> [String]
genShallow (Trace c ins out _ _) = mergeWith (++) [ showTraceStream c v | v <- alldata ]
    where alldata = (M.elems ins) ++ [out]

genInfo :: Trace -> [String]
genInfo (Trace c ins out _ _) = [ "(" ++ show i ++ ") " ++ l | (i,l) <- zip [1..] lines ]
    where alldata = (M.elems ins) ++ [out]
          lines = mergeWith (\ x y -> x ++ " -> " ++ y) [ showTraceStream c v | v <- alldata ]

writeToFile :: FilePath -> Trace -> IO ()
writeToFile fp t = writeFile fp $ serialize t

readFromFile :: FilePath -> IO Trace
readFromFile fp = do
    str <- readFile fp
    return $ deserialize str

-- return true if running circuit with trace gives same outputs as that contained by the trace
checkExpected :: (Run a) => a -> Trace -> (Bool, Trace)
checkExpected circuit trace = (trace == result, result)
    where result = execute circuit trace

execute :: (Run a) => a -> Trace -> Trace
execute circuit trace = trace { outputs = run circuit trace }

class Run a where
    run :: a -> Trace -> TraceStream

instance (Rep a) => Run (CSeq c a) where
    run (Seq s _) (Trace c _ _ _ _) = TraceStream ty $ takeMaybe c strm
        where TraceStream ty strm = fromXStream (witness :: a) s

{- eventually
instance (Rep a) => Run (Comb a) where
    run (Comb s _) (Trace c _ _ _ _) = (wireType witness, take c $ fromXStream witness (fromList $ repeat s))
        where witness = (error "run trace" :: a)
-}

instance (Run a, Run b) => Run (a,b) where
    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y) t = TraceStream (TupleTy [ty1,ty2]) $ zipWith appendRepValue strm1 strm2
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t

instance (Run a, Run b, Run c) => Run (a,b,c) where
    -- note order of zip matters! must be consistent with fromWireXRep
    run (x,y,z) t = TraceStream (TupleTy [ty1,ty2,ty3]) (zipWith appendRepValue strm1 $ zipWith appendRepValue strm2 strm3)
        where TraceStream ty1 strm1 = run x t
              TraceStream ty2 strm2 = run y t
              TraceStream ty3 strm3 = run z t

instance (Rep a, Run b) => Run (Seq a -> b) where
    run fn t@(Trace c ins _ _ _) = run (fn input) $ t { inputs = M.delete key ins }
        where key = head $ M.keys ins
              input = getSeq key ins (witness :: a)

instance (Rep a, Run b) => Run (Comb a -> b) where
    run fn t@(Trace c ins _ _ _) = run (fn input) $ t { inputs = M.delete key ins }
        where key = head $ M.keys ins
              input = getComb key ins (witness :: a)

-- TODO: generalize over different clocks
instance (Run b) => Run (Env () -> b) where
    run fn t@(Trace c ins _ _ _) = run (fn input) $ t { inputs = M.delete key1 $ M.delete key2 $ ins }
        where [key1,key2] = take 2 $ M.keys ins
              input = shallowEnv
			{ resetEnv = getSeq key1 ins (witness :: Bool)
			, enableEnv = getSeq key2 ins (witness :: Bool)
			}

-- TODO: generalize somehow?
instance (Enum (Matrix.ADD (WIDTH a) (WIDTH b)),
          Matrix.Size (Matrix.ADD (WIDTH a) (WIDTH b)),
          Rep a, Rep b, Run c) => Run ((Seq a, Seq b) -> c) where
    run fn t@(Trace c ins _ _ _) = run (fn input) $ t { inputs = M.delete key ins }
        where key = head $ M.keys ins
              input = unpack $ getSeq key ins (witness :: (a,b))

-- These are exported, but are not intended for the end user.

-- Some combinators to get stuff in and out of the map
fromXStream :: forall w. (Rep w) => w -> Stream (X w) -> TraceStream
fromXStream witness stream = TraceStream (wireType witness) [toRep witness xVal | xVal <- Stream.toList stream ]

-- oh to have dependent types!
toXStream :: forall w. (Rep w) => w -> TraceStream -> Stream (X w)
toXStream witness (TraceStream _ list) = Stream.fromList [fromRep witness $ val | val <- list]

-- Functions below are not exported.

-- if Nothing, take whole list, otherwise, normal take with the Int inside the Just
takeMaybe :: Maybe Int -> [a] -> [a]
takeMaybe = maybe id take

toXBit :: Maybe Bool -> Char
toXBit = maybe 'X' (\b -> if b then '1' else '0')

-- note the reverse here is crucial due to way vhdl indexes stuff
showTraceStream :: Maybe Int -> TraceStream -> [String]
showTraceStream c (TraceStream _ s) = [map (toXBit . unX) $ reverse val | RepValue val <- takeMaybe c s]

readStrm :: [String] -> (TraceStream, [String])
readStrm ls = (strm,rest)
    where (m,rest) = readMap ls
          [(_,strm)] = M.toList (m :: TraceMap OVar)

readMap :: (Ord k, Read k) => [String] -> (TraceMap k, [String])
readMap ls = (go $ takeWhile cond ls, rest)
    where cond = (not . (flip elem) ["INPUTS","OUTPUT","PROBES"])
          rest = dropWhile cond ls
          go (k:ty:strm:r) = M.union (M.singleton (read k) (TraceStream (read ty) ([RepValue $ map toXBool w | w <- words strm]))) $ go r
          go _             = M.empty
          toXBool :: Char -> X Bool
          toXBool '1' = return True
          toXBool '0' = return False
          toXBool _   = fail "unknown"

getStream :: forall a w. (Ord a, Rep w) => a -> TraceMap a -> w -> Stream (X w)
getStream name m witness = toXStream witness $ m M.! name

getSeq :: (Ord a, Rep w) => a -> TraceMap a -> w -> Seq w
getSeq key m witness = shallowSeq $ getStream key m witness

-- Note: this only gets the *first* value. Perhaps combs should be stored differently?
getComb :: (Ord a, Rep w) => a -> TraceMap a -> w -> Comb w
getComb key m witness = shallowComb $ Stream.head $ getStream key m witness

addStream :: forall a w. (Ord a, Rep w) => a -> TraceMap a -> w -> Stream (X w) -> TraceMap a
addStream key m witness stream = M.insert key (fromXStream witness stream) m

addSeq :: forall a b. (Ord a, Rep b) => a -> Seq b -> TraceMap a -> TraceMap a
addSeq key seq m = addStream key m (witness :: b) (seqValue seq :: Stream (X b))

