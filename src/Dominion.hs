{-# LANGUAGE TemplateHaskell #-}

module Dominion (Option(..), module Dominion) where
import Prelude hiding (log)
import qualified Dominion.Types as T
import Dominion.Types (Option(..))
import qualified Dominion.Cards as CA
import Control.Monad
import Data.Maybe
import Control.Monad.State hiding (state)
import Control.Lens hiding (has)
import Control.Monad.IO.Class
import Text.Printf
import Data.List
import Control.Monad
import Dominion.Utils
import Data.Either
import Control.Applicative
import Dominion.Internal

makePlayer :: String -> T.Player
makePlayer name = T.Player name [] (7 `cardsOf` CA.copper ++ 3 `cardsOf` CA.estate) [] 1 1 0

uses :: String -> T.Strategy -> (T.Player, T.Strategy)
name `uses` strategy = ((makePlayer name), strategy)

dominion :: [(T.Player, T.Strategy)] -> IO ()
dominion = dominionWithOpts []

dominionWithOpts :: [T.Option] -> [(T.Player, T.Strategy)] -> IO ()
dominionWithOpts options list = do
    let players = map fst list
        strategies = map snd list
        iterations = findIteration options |||| 1000
        verbose_ = findLog options |||| False
    results <- forM [1..iterations] $ \i -> if even i
                                        then run (T.GameState players cards 1 verbose_) strategies
                                        else run (T.GameState (reverse players) cards 1 verbose_) strategies
    forM_ players $ \player -> do
      let name = player ^. T.playerName
      putStrLn $ printf "player %s won %d times" name (count name results)

cards = concatMap pileOf [ CA.copper,
                           CA.silver,
                           CA.gold,
                           CA.estate,
                           CA.duchy,
                           CA.province,
                           CA.curse,
                           CA.smithy,
                           CA.village,
                           CA.laboratory,
                           CA.festival,
                           CA.market,
                           CA.woodcutter ]

-- player buys a card
buys :: T.PlayerId -> T.Card -> T.Dominion (Either String ())
buys playerId card = do
    validation <- validateBuy playerId card
    case validation of
      Left x -> return $ Left x
      Right _ -> do
                   money <- handValue playerId
                   modifyPlayer playerId $ \p -> over T.discard (card:) $
                                                 over T.buys (subtract 1) $
                                                 -- this works because extraMoney can be negative
                                                 over T.extraMoney (subtract $ card ^. T.cost) p
                   modify $ over T.cards (delete card)
                   log playerId $ printf "bought a %s" (card ^. T.name)
                   return $ Right ()

-- Give an array of cards, in order of preference of buy.
-- We'll try to buy as many cards as possible, in order of preference.
buysByPreference :: T.PlayerId -> [T.Card] -> T.Dominion ()
buysByPreference playerId cards = do
    player <- getPlayer playerId
    when ((player ^. T.buys) > 0) $ do
      purchasableCards <- filterM (eitherToBool <$> validateBuy playerId) cards
      when (not (null purchasableCards)) $ do
        playerId `buys` (head purchasableCards)
        playerId `buysByPreference` cards

-- Give an array of cards, in order of preference of play.
-- We'll try to play as many cards as possible, in order of preference.
playsByPreference :: T.PlayerId -> [T.Card] -> T.Dominion ()
playsByPreference playerId cards = do
    player <- getPlayer playerId
    when ((player ^. T.actions) > 0) $ do
      playableCards <- filterM (\card -> eitherToBool <$> validatePlay playerId card) cards
      when (not (null playableCards)) $ do
        playerId `plays` (head playableCards)
        playerId `playsByPreference` cards

-- player plays an action card. We return an Either.
-- On error, we'll return an error message.
-- On success, we will return either:
--  Nothing, if there are no followup actions to be taken.
--  (playerId, card effect), if that effect has a folow-up
--  action that needs to be taken, such as when throne room
--  is played...you need to then select an action card to
--  play twice.
--
--  You can use the followup with `with`.
plays :: T.PlayerId -> T.Card -> T.Dominion (Either String (Maybe (T.PlayerId, T.CardEffect)))
plays playerId card = do
    validation <- validatePlay playerId card
    case validation of
      Left x -> return $ Left x
      Right _ -> do
               log playerId $ printf "plays a %s!" (card ^. T.name)
               results <- mapM (\effect -> playerId `usesEffect` effect) (card ^. T.effects)
               modifyPlayer playerId $ \player -> over T.hand (delete card) $ over T.discard (card:) $ over T.actions (subtract 1) $ player
               -- we should get at most *one* effect to return
               return $ Right $ case (catMaybes results) of
                          [] -> Nothing
                          [result] -> Just result

-- `with` might lead to more extra effects. And specifically, lets say you
-- play throne room on throne room. Now you have TWO extra effects, i.e.
-- you can choose a card to play twice TWICE.
--
-- Thats why `with` might return an array of extra effects, not just one.
with :: T.Dominion (Either String (Maybe (T.PlayerId, T.CardEffect))) -> T.ExtraEffect -> T.Dominion (Either String (Maybe [(T.PlayerId, T.CardEffect)]))
info `with` extraEffect = do
    result <- info
    result `_with` extraEffect

-- just like `with`, except you can give it an array of info, and an
-- array of the extra effects you want to use with each info
withMulti :: T.Dominion (Either String (Maybe [(T.PlayerId, T.CardEffect)])) -> [T.ExtraEffect] -> T.Dominion (Either String (Maybe [(T.PlayerId, T.CardEffect)]))
info `withMulti` extraEffects = do
    results_ <- info
    case results_ of
      Right (Just results) -> do
          allResults <- forM (zip results extraEffects) $ \(result, extraEffect) -> (Right (Just result)) `_with` extraEffect
          return $ Right (Just (concat . catMaybes . rights $ allResults))
      Left str -> return $ Left str
      _ -> return $ Right Nothing

-- private method, use if you don't want to pass in a state monad into
-- `with`. This is what `with` uses behind the scenes.
_with :: Either String (Maybe (T.PlayerId, T.CardEffect)) -> T.ExtraEffect -> T.Dominion (Either String (Maybe [(T.PlayerId, T.CardEffect)]))
Left str `_with` _ = return $ Left str
Right Nothing `_with` _ = return $ Right Nothing

Right (Just (playerId, T.PlayActionCard x)) `_with` (T.ThroneRoom card) = do
  player <- getPlayer playerId
  if not (card `elem` (player ^. T.hand))
    then return . Left $ printf "You can't play a %s because you don't have it in your hand!" (card ^. T.name)
    else do
      log playerId $ printf "playing %s twice!" (card ^. T.name)
      results <- mapM (\effect -> playerId `usesEffect` effect) (card ^. T.effects)
      results2 <- mapM (\effect -> playerId `usesEffect` effect) (card ^. T.effects)
      modifyPlayer playerId $ \player -> over T.hand (delete card) $ over T.discard (card:) player
      let finalResults = catMaybes (results ++ results2)
      return $ Right $ case finalResults of
                 [] -> Nothing
                 x -> Just x

_ `_with` _ = return $ Left "sorry, you can't play that effect with that extra effect."

-- see if a player has a card in his hand
has :: T.PlayerId -> T.Card -> T.Dominion Bool
has playerId card = do
    player <- getPlayer playerId
    return $ card `elem` (player ^. T.hand)
