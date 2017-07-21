{-# LANGUAGE DataKinds, GADTs, TypeOperators #-}
module Semantic.Task
( Task
, RAlgebra
, Message(..)
, Differ
, readBlobs
, readBlobPairs
, writeToOutput
, writeLog
, parse
, decorate
, diff
, render
, distribute
, distributeFor
, distributeFoldMap
, runTask
) where

import Control.Parallel.Strategies
import qualified Control.Concurrent.Async as Async
import Control.Monad.Free.Freer
import Data.Blob
import qualified Data.ByteString as B
import Data.Functor.Both as Both
import Data.Record
import Data.Syntax.Algebra (RAlgebra, decoratorWithAlgebra)
import Diff
import qualified Files
import Language
import Parser
import Prologue
import Term

data TaskF output where
  ReadBlobs :: Either Handle [(FilePath, Maybe Language)] -> TaskF [Blob]
  ReadBlobPairs :: Either Handle [Both (FilePath, Maybe Language)] -> TaskF [Both Blob]
  WriteToOutput :: Either Handle FilePath -> ByteString -> TaskF ()
  WriteLog :: Message -> TaskF ()
  Parse :: Parser term -> Blob -> TaskF term
  Decorate :: Functor f => RAlgebra (TermF f (Record fields)) (Term f (Record fields)) field -> Term f (Record fields) -> TaskF (Term f (Record (field ': fields)))
  Diff :: Differ f a -> Both (Term f a) -> TaskF (Diff f a)
  Render :: Renderer input output -> input -> TaskF output
  Distribute :: Traversable t => t (Task output) -> TaskF (t output)

-- | A high-level task producing some result, e.g. parsing, diffing, rendering. 'Task's can also specify explicit concurrency via 'distribute', 'distributeFor', and 'distributeFoldMap'
type Task = Freer TaskF

-- | A log message at a specific level.
data Message
  = Error { messageContent :: ByteString }
  | Warning { messageContent :: ByteString }
  | Info { messageContent :: ByteString }
  | Debug { messageContent :: ByteString }
  deriving (Eq, Show)

formatMessage :: Message -> ByteString
formatMessage (Error s) = "error: " <> s <> "\n"
formatMessage (Warning s) = "warning: " <> s <> "\n"
formatMessage (Info s) = "info: " <> s <> "\n"
formatMessage (Debug s) = "debug: " <> s <> "\n"

-- | A function to compute the 'Diff' for a pair of 'Term's with arbitrary syntax functor & annotation types.
type Differ f a = Both (Term f a) -> Diff f a

-- | A function to render terms or diffs.
type Renderer i o = i -> o

-- | A 'Task' which reads a list of 'Blob's from a 'Handle' or a list of 'FilePath's optionally paired with 'Language's.
readBlobs :: Either Handle [(FilePath, Maybe Language)] -> Task [Blob]
readBlobs from = ReadBlobs from `Then` return

-- | A 'Task' which reads a list of pairs of 'Blob's from a 'Handle' or a list of pairs of 'FilePath's optionally paired with 'Language's.
readBlobPairs :: Either Handle [Both (FilePath, Maybe Language)] -> Task [Both Blob]
readBlobPairs from = ReadBlobPairs from `Then` return

-- | A 'Task' which writes a 'ByteString' to a 'Handle' or a 'FilePath'.
writeToOutput :: Either Handle FilePath -> ByteString -> Task ()
writeToOutput path contents = WriteToOutput path contents `Then` return


-- | A 'Task' which logs a message at a specific log level to stderr.
writeLog :: Message -> Task ()
writeLog message = WriteLog message `Then` return


-- | A 'Task' which parses a 'Blob' with the given 'Parser'.
parse :: Parser term -> Blob -> Task term
parse parser blob = Parse parser blob `Then` return

-- | A 'Task' which decorates a 'Term' with values computed using the supplied 'RAlgebra' function.
decorate :: Functor f => RAlgebra (TermF f (Record fields)) (Term f (Record fields)) field -> Term f (Record fields) -> Task (Term f (Record (field ': fields)))
decorate algebra term = Decorate algebra term `Then` return

-- | A 'Task' which diffs a pair of terms using the supplied 'Differ' function.
diff :: Differ f a -> Both (Term f a) -> Task (Diff f a)
diff differ terms = Diff differ terms `Then` return

-- | A 'Task' which renders some input using the supplied 'Renderer' function.
render :: Renderer input output -> input -> Task output
render renderer input = Render renderer input `Then` return

-- | Distribute a 'Traversable' container of 'Task's over the available cores (i.e. execute them concurrently), collecting their results.
--
--   This is a concurrent analogue of 'sequenceA'.
distribute :: Traversable t => t (Task output) -> Task (t output)
distribute tasks = Distribute tasks `Then` return

-- | Distribute the application of a function to each element of a 'Traversable' container of inputs over the available cores (i.e. perform the function concurrently for each element), collecting the results.
--
--   This is a concurrent analogue of 'for' or 'traverse' (with the arguments flipped).
distributeFor :: Traversable t => t a -> (a -> Task output) -> Task (t output)
distributeFor inputs toTask = distribute (fmap toTask inputs)

-- | Distribute the application of a function to each element of a 'Traversable' container of inputs over the available cores (i.e. perform the function concurrently for each element), combining the results 'Monoid'ally into a final value.
--
--   This is a concurrent analogue of 'foldMap'.
distributeFoldMap :: (Traversable t, Monoid output) => (a -> Task output) -> t a -> Task output
distributeFoldMap toTask inputs = fmap fold (distribute (fmap toTask inputs))


-- | Execute a 'Task', yielding its result value in 'IO'.
runTask :: Task a -> IO a
runTask = foldFreer $ \ task -> case task of
  ReadBlobs source -> either Files.readBlobsFromHandle (traverse (uncurry Files.readFile)) source
  ReadBlobPairs source -> either Files.readBlobPairsFromHandle (traverse (traverse (uncurry Files.readFile))) source
  WriteToOutput destination contents -> either B.hPutStr B.writeFile destination contents
  WriteLog message -> B.hPutStr stderr (formatMessage message)
  Parse parser blob -> runParser parser blob
  Decorate algebra term -> pure (decoratorWithAlgebra algebra term)
  Diff differ terms -> pure (differ terms)
  Render renderer input -> pure (renderer input)
  Distribute tasks -> Async.mapConcurrently runTask tasks >>= pure . withStrategy (parTraversable rseq)
