{-# LANGUAGE ExistentialQuantification, ScopedTypeVariables #-}
module Language.KansasLava.Testing.Thunk (Thunk(..), runShallow, runDeep, mkThunk, mkTrace, recordThunk, runTestBench) where

import Language.KansasLava

import Language.KansasLava.Testing.Bench
import Language.KansasLava.Testing.Probes
import Language.KansasLava.Testing.Trace

import Data.List
import qualified Data.Map as M
import Data.Maybe

import System.Cmd
import System.Directory
import System.FilePath.Posix
import System.Posix.Directory

data Thunk b = forall a. (Ports a, Probe a, Run a, Ports b) => Thunk a (a -> b)

instance (Show b) => Show (Thunk b) where
   show thunk = show $ runShallow thunk

-- | Make a Trace from a Thunk
mkTrace :: (Ports a)
        => Maybe Int -- ^ Nothing means infinite trace, Just x sets trace length to x cycles.
        -> Thunk a   -- ^ The thunk we are executing.
        -> IO Trace
mkTrace c (Thunk circuit k) = do
    let uname = "wholeCircuit5471" -- probably need a better solution than this
    let probed = probe uname circuit

    rc <- reifyCircuit $ k $ probed

    let pdata = [ (k,v) | (_,Entity _ _ _ attrs) <- theCircuit rc
                       , ProbeValue k v <- attrs ]
        io = sortBy (\(k1,_) (k2,_) -> compare k1 k2) [ s | s@(OVar _ name, _) <- pdata, uname `isPrefixOf` name ]
        ins = M.fromList $ init io
        out = snd $ last io
        ps = M.fromList pdata M.\\ M.fromList io

    -- signature generation is broken (no inputs) because rc is circuit with inputs applied
    return $ Trace { len = c, inputs = ins, outputs = out, probes = ps, signature = circuitSignature rc }

-- | Make a Thunk from a Trace and a (non-reified) lava circuit.
mkThunk :: forall a b. (Ports a, Probe a, Run a, Rep b)
        => Trace -- ^ A (possibly partial) trace to supply inputs.
        -> a     -- ^ The lava circuit.
        -> Thunk (Seq b)
mkThunk trace circuit = Thunk circuit (\c -> shallowSeq $ toXStream (witness :: b) $ run c trace)

-- | Like mkTrace, but also generates a VHDL testbench and input files.
-- | Since we must shallowly run the thunk to generate the input, this returns a
-- | trace as a convenience.
recordThunk :: (Ports b)
            => FilePath -- ^ Directory where we should place testbench files. Will be created if it doesn't exist.
            -> Int      -- ^ Generate inputs for this many cycles.
            -> (Circuit -> IO Circuit)  -- ^ any operations on the circuit before VHDL generation
            -> Thunk b
            -> IO Trace
recordThunk path cycles circuitMod thunk@(Thunk c k) = do
    let name = last $ splitPath path

    createDirectoryIfMissing True path

    trace <- mkTrace (return cycles) thunk

    writeFile (path </> name <.> "shallow") $ unlines $ genShallow trace
    writeFile (path </> name <.> "info") $ unlines $ genInfo trace

    rc <- reifyCircuit c

    rc' <- circuitMod rc

    mkTestbench name path rc'

    return trace

-- | Execute a Thunk
runShallow :: Thunk b -> b
runShallow (Thunk circuit fn) = fn circuit

-- | Combination of recordThunk and runTestBench, working in the temp directory.
-- eventually runDeep :: (Ports b) => String -> Int -> Thunk b -> (FilePath -> IO ()) -> IO Trace
runDeep :: (Ports b)
        => String              -- ^ User significant name for the Thunk
        -> Int                 -- ^ Number of cycles to simulate.
        -> Thunk b
        -> (Circuit -> IO Circuit) -- ^ any operations on the circuit before VHDL generation
        -> (FilePath -> IO ()) -- ^ Invocation function, given a path to the testbench and charged with actually executing the test. Can assume path exists.
        -> IO ()
runDeep name cycles thunk circuitMod invoker = do
    tmp <- getTemporaryDirectory

    let target = tmp </> name

    recordThunk target cycles circuitMod thunk
    runTestBench target invoker

    -- there better not be any symlinks in here!
    removeDirectoryRecursive target

-- | Run a generated testbench.
-- eventually runTestBench :: FilePath -> (FilePath -> IO ()) -> IO Trace
runTestBench :: FilePath            -- ^ Path to testbench we want to run.
             -> (FilePath -> IO ()) -- ^ Invocation function, given a path to the testbench and charged with actually executing the test. Can assume path exists.
             -> IO ()
runTestBench path invoker = do
    exists <- doesDirectoryExist path

    if exists
        then invoker path
        else putStrLn $ "runTestBench: " ++ path ++ " does not exist!"

    -- eventually we will read the deep file here and return it as a trace

