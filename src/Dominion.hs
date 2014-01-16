{-# LANGUAGE TemplateHaskell #-}

module Dominion where
import qualified Player as P
import qualified Card as C
import Control.Monad
import Data.Maybe
import Control.Monad.State
import Control.Concurrent
import Control.Lens
import Control.Monad.IO.Class
import Text.Printf
import Data.List
import Data.Random.Extras
import Data.Random hiding (shuffle)
import System.Random
import System.IO.Unsafe

for = flip map
forM_ = flip mapM_

myShuffle :: [C.Card] -> IO [C.Card]
myShuffle deck = do
    gen <- getStdGen
    let (shuffled, newGen) = sampleState (shuffle deck) gen
    setStdGen newGen
    return shuffled

type PlayerId = Int

data GameState = GameState {
                    _players :: [P.Player],
                    _cards :: [C.Card]
} deriving Show

makeLenses ''GameState

-- get player from game state
getPlayer :: PlayerId -> StateT GameState IO P.Player
getPlayer playerId = do
    state <- get
    return $ (state ^. players) !! playerId

-- takes a player id and a function.
-- That function takes a player and returns a modified player.
modifyPlayer :: PlayerId -> (P.Player -> P.Player) -> StateT GameState IO ()
modifyPlayer playerId func = modify $ \state -> over (players . element playerId) func $ state


shuffleDeck playerId = modifyPlayer playerId shuffleDeck_

shuffleDeck_ player = set P.discard [] $ set P.deck newDeck player
          where discard = player ^. P.discard
                deck    = player ^. P.deck
                newDeck = unsafePerformIO $ myShuffle (deck ++ discard)

-- only gets called when we know that the player has at least 5 cards in
-- his/her deck
drawFromFull playerId = modifyPlayer playerId $ \player -> 
                            over P.deck (drop 5) $ 
                              over P.hand (++ (take 5 (player ^. P.deck))) player
 
-- draw 5 cards from the deck of a player. Returns the drawn cards.
drawFromDeck :: PlayerId -> StateT GameState IO ()
drawFromDeck playerId = do
    player <- getPlayer playerId
    let deck = player ^. P.deck
    if (length deck) >= 5
      then drawFromFull playerId
      else shuffleDeck playerId >> drawFromFull playerId

-- number of treasures this hand has
handValue :: PlayerId -> StateT GameState IO Int
handValue playerId = do
    player <- getPlayer playerId
    return $ sum (map coinValue (player ^. P.hand)) + (player ^. P.extraMoney)

coinValue :: C.Card -> Int
coinValue card = sum $ map effect (C.effects card)
          where effect (C.CoinValue num) = num
                effect _ = 0

-- player purchases a card
purchases :: PlayerId -> C.Card -> StateT GameState IO ()
purchases playerId card = do
    modifyPlayer playerId $ over P.discard (card:)
    modify $ \state_ -> set cards (delete card (state_ ^. cards)) state_
    liftIO $ putStrLn $ printf "player %d purchased a %s" playerId (C.name card)

discardHand :: PlayerId -> StateT GameState IO ()
discardHand playerId = modifyPlayer playerId $ \player -> over P.discard (++ (player ^. P.hand)) player

-- the big money strategy
bigMoney playerId = do
    money <- handValue playerId
    bigMoney_ playerId money

bigMoney_ playerId money
    | money >= 8 = playerId `purchases` C.province
    | money >= 6 = playerId `purchases` C.gold
    | money >= 5 = playerId `purchases` C.duchy
    | money >= 3 = playerId `purchases` C.silver
    | otherwise  = playerId `purchases` C.copper

-- player plays given strategy
playTurn playerId strategy = do
    drawFromDeck playerId
    strategy playerId
    discardHand playerId

game :: StateT GameState IO ()
game = do
         state <- get
         forM_ (zip (state ^. players) [0..]) $ \(_, p_id) -> playTurn p_id bigMoney
