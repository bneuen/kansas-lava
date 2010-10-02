module Language.KansasLava.Circuit.Optimization
	( optimizeCircuit
	, OptimizationOpts(..)
	, Opt
	, runOpt
	) where

import Language.KansasLava.Types
import Data.Reify
import qualified Data.Traversable as T
import Language.KansasLava.Types
import Language.KansasLava.Wire
import Language.KansasLava.Entity
import Language.KansasLava.Entity.Utils
import Language.KansasLava.Circuit
import Control.Monad

import Data.List
import Data.Default

import Debug.Trace

import Data.List

-- NOTES:
-- We need to update the Lava::id operator, that can take and return *multiple* values.

-- A very simple optimizer.

-- This returns an optimized version of the Entity, or fails to optimize.
optimizeEntity :: (Unique -> MuE Unique) -> MuE Unique -> Maybe (MuE Unique)
optimizeEntity env (Entity (Name "Lava" "fst") [(o0,tO)] [(i0,tI,Port o0' u)] []) =
	case env u of
	    Entity (Name "Lava" "pair") [(o0'',tI')] [(i1',t1,p1),(i2',t2,p2)] []
	       | o0' == o0'' -> return $ replaceWith o0 (i1',t1,p1)
	    _ -> Nothing
optimizeEntity env (Entity (Name "Lava" "snd") [(o0,tO)] [(i0,tI,Port o0' u)] []) =
	case env u of
	    Entity (Name "Lava" "pair") [(o0'',tI')] [(i1',t1,p1),(i2',t2,p2)] []
	       | o0' == o0'' -> return $ replaceWith o0 (i2',t2,p2)
	    _ -> Nothing
optimizeEntity env (Entity (Name "Lava" "pair") [(o0,tO)] [(i0,tI0,Port o0' u0),(i1,tI1,Port o1' u1)] []) =
	case (env u0,env u1) of
	    ( Entity (Name "Lava" "fst") [(o0'',_)] [(i0',tI0',p2)] []
	      , Entity (Name "Lava" "snd") [(o1'',_)] [(i1',tI1',p1)] []
	      ) | o0' == o0'' && o1' == o1'' && p1 == p2 ->
			return $ replaceWith o0 ("o0",tO,p1)
	    _ -> Nothing
optimizeEntity env (Entity (Name _ "mux2") [(o0,_)] [(i0,cTy,c),(i1 ,tTy,t),(i2,fTy,f)] _)
    | t == f = return $ replaceWith o0 (i1,tTy,t)
    | otherwise = Nothing
optimizeEntity env _ = Nothing

----------------------------------------------------------------------

replaceWith o (i,t,other) = Entity (Name "Lava" "id") [(o,t)] [(i,t,other)] []
--replaceWith (i,t,x) = error $ "replaceWith " ++ show (i,t,x)

----------------------------------------------------------------------

data Opt a = Opt a Int -- [String]

instance Monad Opt where
    return a = Opt a 0
    (Opt a n) >>= k = case k a of
	 		Opt r m -> Opt r (n + m)

runOpt :: Opt a -> (a,[String])
runOpt (Opt a i) = (a,if i == 0
		      then []
		      else [show i ++ " optimizations"]
		   )


----------------------------------------------------------------------

-- copy elimination
copyElimCircuit :: Circuit -> Opt Circuit
copyElimCircuit rCir =  Opt rCir' (length renamings)
    where
	env0 = theCircuit rCir

	rCir' = rCir
	      { theSinks =
		  [ ( v,t,
		      case d of
		        Port p u -> case lookup (u,p) renamings of
				      Just other -> other
				      Nothing    -> Port p u
			Pad v -> Pad v
			Lit i -> Lit i
			Error i -> error $ "Found Error : " ++ show (i,v,t,d)
		    )
		  | (v,t,d) <- theSinks rCir
		  ]
	      , theCircuit =
		 [ (u,case e of
			Entity nm outs ins tags -> Entity nm outs (map fixInPort ins) tags
		   )
		 | (u,e) <- env0
		 ]
	      }

	renamings = [ ((u,o),other)
		    | (u,Entity (Name "Lava" "id") [(o,tO)] [(i,tI,other)] []) <- env0
		    , tO == tI	-- should always be, anyway
		    ]

	fixInPort (i,t,Port p u) =
			    (i,t, case lookup (u,p) renamings of
				     Just other -> other
				     Nothing    -> Port p u)
	fixInPort (i,t,o) = (i,t,o)


--
-- Starting CSE.
cseCircuit :: Circuit -> Opt Circuit
cseCircuit rCir = Opt  (rCir { theCircuit = concat rCirX }) cseCount
   where

	-- how many CSE's did we spot?
	cseCount = length (theCircuit rCir) - length rCirX

	-- for now, just use show: this is what has changed
	optMsg = [ (u,e)
	         | (u,e) <- (theCircuit rCir)
		 , not (u `elem` (map fst (map head rCirX)))
	         ]

	rCirX :: [[(Unique, MuE Unique)]]
	rCirX = map canonicalize
		-- We want to combine anything *except* idents's
		-- because we would just replace them with new idents's (not a problem)
		-- _and_ say we've found some optimization (which *is* a problem).
	      $ groupBy (\ (a,b) (a',b') -> (b `mycompare` b') == EQ && not (isId b))
	      $ sortBy (\ (a,b) (a',b') -> b `mycompare` b')
	      $ theCircuit rCir


	isId (Entity (Name "Lava" "id") _ _ _) = True
	isId _ = False

	-- The outputs do not form part of the comparison here,
	-- because they *can* be different, without effecting
	-- the CSE opertunity.
	mycompare (Entity nm outs ins misc)
	 	  (Entity nm' outs' ins' misc') =
		chain
		  [ nm `compare` nm'
		  , ins `compare` ins'
		  , misc `compare` misc'
		  ]

	chain (LT:_ ) = LT
	chain (GT:_ ) = GT
	chain (EQ:xs) = chain xs
	chain []      = EQ

	-- Build the identites

	canonicalize ((u0,e0@(Entity _ outs _ _)):rest) =
		(u0,e0) : [ ( uX
		            , case eX of
			     	Entity nm' outs' _ _ | length outs == length outs'
				  -> Entity (Name "Lava" "id") outs' [ (n,t, Port n u0) | (n,t) <- outs ] []
			    )
			  | (uX,eX) <- rest
			  ]

dceCircuit :: Circuit -> Opt Circuit
dceCircuit rCir = if optCount == 0
			 then return rCir
			 else Opt  rCir' optCount
  where
	optCount = length (theCircuit rCir) - length optCir

	outFrees (_,_,Port _ u) = [u]
	outFrees _             = []

	allNames :: [Unique]
	allNames = nub (concat
		       [ case e of
			  Entity nm _ outs _ -> concatMap outFrees outs
		       | (u,e) <- theCircuit rCir
		       ] ++ concatMap outFrees (theSinks rCir)
		       )

	optCir = [ (uq,orig)
		 | (uq,orig) <- theCircuit rCir
		 , uq `elem` allNames
		 ]
	rCir' = rCir { theCircuit = optCir }

-- return Nothing *if* no optimization can be found.
patternMatchCircuit :: Circuit -> Opt Circuit
patternMatchCircuit rCir = if optCount == 0
			      then return rCir	-- no changes
			      else Opt rCir' optCount
  where
	env0 = theCircuit rCir
	env1 v = case lookup v env0 of
		   Nothing -> error $ "oops, can not find " ++ show v
		   Just e -> e

	attemptOpt = [ optimizeEntity env1 e | (u,e) <- theCircuit rCir ]
	optCount = length [ () | (Just _) <- attemptOpt ]

	optCir = [ (uq,case mOpt of
			 Nothing -> orig
			 Just opt -> opt)
		 | ((uq,orig),mOpt) <- zip (theCircuit rCir) attemptOpt
		 ]

	rCir' = rCir { theCircuit = optCir }

optimizeCircuits :: [(String,Circuit -> Opt Circuit)] -> Circuit -> [(String,Opt Circuit)]
optimizeCircuits ((nm,fn):fns) c = (nm,opt) : optimizeCircuits fns c'
	where opt@(Opt c' n) = case fn c of
				 Opt c' 0 -> Opt c 0	-- If there was no opts, avoid churn
				 Opt c' n' -> Opt c' n'



data OptimizationOpts = OptimizationOpts
	{ optDebugLevel :: Int
	}

instance Default OptimizationOpts
   where
	def = OptimizationOpts
		{ optDebugLevel = 0
		}


-- Basic optimizations, and assumes reaching a fixpoint :-)
optimizeCircuit :: OptimizationOpts -> Circuit -> IO Circuit
optimizeCircuit options rCir = do
	when debug $ do
		print rCir
	loop (optimizeCircuits (cycle opts) rCir)
   where
	debug = optDebugLevel options > 0
	loop cs@((nm,Opt code n):_) = do
		when debug $ do
		  putStrLn $ "##[" ++ nm ++ "](" ++ show n ++ ")###################################"
		  when (n > 0) $ do
			print code
		case cs of
		    ((nm,Opt c _):_) | and [ n == 0 | (_,Opt c n) <- take (length opts) cs ] -> return c
		    ((nm,Opt c v):cs) -> loop cs

	opts = [ ("opt",patternMatchCircuit)
	       , ("cse",cseCircuit)
	       , ("copy",copyElimCircuit)
	       , ("dce",dceCircuit)
	       ]
