module Cleff.Error
  ( -- * Effect
    Error (..)
  , -- * Operations
    throwError, catchError, fromEither, fromException, fromExceptionVia, fromExceptionEff, fromExceptionEffVia,
    note, catchErrorJust, catchErrorIf, handleError, handleErrorJust, handleErrorIf, tryError, tryErrorJust
  , -- * Interpretations
    runError, mapError
  ) where

import           Cleff
import           Cleff.Internal.Base (thisIsPureTrustMe)
import           Control.Exception   (Exception)
import           Data.Bool           (bool)
import           Data.Unique         (Unique, newUnique)
import           Type.Reflection     (Typeable, typeOf)
import qualified UnliftIO.Exception  as Exc

-- | An effect capable of breaking out of current control flow by raising an exceptional value @e@. This effect roughly
-- corresponds to the @MonadError@ typeclass and @ExceptT@ monad transformer in @mtl@.
data Error e :: Effect where
  ThrowError :: e -> Error e m a
  CatchError :: m a -> (e -> m a) -> Error e m a
makeEffect ''Error

-- | Lift an 'Either' value into the 'Error' effect.
fromEither :: Error e :> es => Either e a -> Eff es a
fromEither = either throwError pure

-- | Lift exceptions generated by an 'IO' action into the 'Error' effect.
fromException :: forall e es a. (Exc.Exception e, '[Error e, IOE] :>> es) => IO a -> Eff es a
fromException m = Exc.catch (liftIO m) (throwError @e)

-- | Like 'fromException', but allows to transform the exception into another error type.
fromExceptionVia :: (Exc.Exception ex, '[Error er, IOE] :>> es) => (ex -> er) -> IO a -> Eff es a
fromExceptionVia f m = Exc.catch (liftIO m) (throwError . f)

-- | Lift exceptions generated by an 'Eff' action into the 'Error' effect.
fromExceptionEff :: forall e es a. (Exc.Exception e, '[Error e, IOE] :>> es) => Eff es a -> Eff es a
fromExceptionEff m = withRunInIO \unlift -> Exc.catch (unlift m) (unlift . throwError @e)

-- | Like 'fromExceptionEff', but allows to transform the exception into another error type.
fromExceptionEffVia :: (Exc.Exception ex, '[Error er, IOE] :>> es) => (ex -> er) -> Eff es a -> Eff es a
fromExceptionEffVia f m = withRunInIO \unlift -> Exc.catch (unlift m) (unlift . throwError . f)

-- | Try to extract a value from 'Maybe', throw an error otherwise.
note :: Error e :> es => e -> Maybe a -> Eff es a
note e = maybe (throwError e) pure

-- | A variant of 'catchError' that allows a predicate to choose whether to catch ('Just') or rethrow ('Nothing') the
-- error.
catchErrorJust :: Error e :> es => (e -> Maybe b) -> Eff es a -> (b -> Eff es a) -> Eff es a
catchErrorJust f m h = m `catchError` \e -> maybe (throwError e) h $ f e

-- | A variant of 'catchError' that allows a predicate to choose whether to catch ('True') or rethrow ('False') the
-- error.
catchErrorIf :: Error e :> es => (e -> Bool) -> Eff es a -> (e -> Eff es a) -> Eff es a
catchErrorIf f m h = m `catchError` \e -> bool (throwError e) (h e) $ f e

-- | Flipped version of 'catchError'.
handleError :: Error e :> es => (e -> Eff es a) -> Eff es a -> Eff es a
handleError = flip catchError

-- | Flipped version of 'catchErrorJust'.
handleErrorJust :: Error e :> es => (e -> Maybe b) -> (b -> Eff es a) -> Eff es a -> Eff es a
handleErrorJust = flip . catchErrorJust

-- | Flipped version of 'catchErrorIf'.
handleErrorIf :: Error e :> es => (e -> Bool) -> (e -> Eff es a) -> Eff es a -> Eff es a
handleErrorIf = flip . catchErrorIf

-- | Runs an action, returning a 'Left' value if an error was thrown.
tryError :: Error e :> es => Eff es a -> Eff es (Either e a)
tryError m = (Right <$> m) `catchError` (pure . Left)

-- | A variant of 'tryError' that allows a predicate to choose whether to catch ('True') or rethrow ('False') the
-- error.
tryErrorJust :: Error e :> es => (e -> Maybe b) -> Eff es a -> Eff es (Either b a)
tryErrorJust f m = (Right <$> m) `catchError` \e -> maybe (throwError e) (pure . Left) $ f e

-- | Exception wrapper used in 'runError' in order not to conflate error types with exception types.
data ErrorExc e = ErrorExc !Unique e
instance Typeable e => Show (ErrorExc e) where
  showsPrec p (ErrorExc _ e) =
    ("Cleff.Error.ErrorEx " ++) . showsPrec p (typeOf e)
instance Typeable e => Exception (ErrorExc e)

catch' :: (Typeable e, MonadUnliftIO m) => Unique -> m a -> (e -> m a) -> m a
catch' eid m h = m `Exc.catch` \ex@(ErrorExc eid' e) -> if eid == eid' then h e else Exc.throwIO ex
{-# INLINE catch' #-}

try' :: (Typeable e, MonadUnliftIO m) => Unique -> m a -> m (Either e a)
try' eid m = catch' eid (Right <$> m) (pure . Left)
{-# INLINE try' #-}

-- | Run an 'Error' effect in terms of 'Exc.Exception's.
runError :: forall e es a. Typeable e => Eff (Error e ': es) a -> Eff es (Either e a)
runError m = thisIsPureTrustMe do
  eid <- liftIO newUnique
  try' eid $ reinterpret (\case
    ThrowError e     -> Exc.throwIO $ ErrorExc eid e
    CatchError m' h' -> liftIO $ catch' eid (runInIO m') (runInIO . h')) m
{-# INLINE runError #-}

-- | Transform an 'Error' into another. This is useful for aggregating multiple errors into one type.
mapError :: (Typeable e, Error e' :> es) => (e -> e') -> Eff (Error e ': es) ~> Eff es
mapError f = interpret \case
  ThrowError e   -> throwError $ f e
  CatchError m h -> runError (runHere m) >>= \case
    Left e  -> runThere $ h e
    Right a -> pure a
{-# INLINE mapError #-}
