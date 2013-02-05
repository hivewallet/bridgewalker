{-# LANGUAGE OverloadedStrings #-}
module Bridgewalker
    ( initBridgewalker
    ) where

import Control.Applicative
import Control.Concurrent
import Control.Error
import Control.Monad
import Database.PostgreSQL.Simple
import Data.Serialize
import Network.BitcoinRPC
import Network.BitcoinRPC.Events.MarkerAddresses
import Network.MtGoxAPI

import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64

import AddressUtils
import ClientHub
import CommonTypes
import Config
import DbUtils
import LoggingUtils
import PendingActionsTracker
import Rebalancer

import qualified CommonTypes as CT

myConnectInfo :: B.ByteString
myConnectInfo = "dbname=bridgewalker"

acceptAfterThreeConfs txHeader = thConfirmations txHeader >= 1  -- TODO: set back to 3

periodicRebalancing :: RebalancerHandle -> IO ()
periodicRebalancing rbHandle = forever $ do
    runRebalancer rbHandle
    threadDelay $ 5 * 10 ^ (6 :: Integer)

periodicNudging :: PendingActionsTrackerHandle -> IO ()
periodicNudging patHandle = forever $ do
    nudgePendingActionsTracker patHandle
    threadDelay $ 60 * 10 ^ (6 :: Integer)

initBridgewalkerHandles :: B.ByteString -> IO BridgewalkerHandles
initBridgewalkerHandles connectInfo = do
    (lHandle, appLogger) <- initLogging
    let watchdogLogger = adapt appLogger
    bwConfig <- readConfig
    let maConfig = bcMarkerAddresses bwConfig
    dbConn1 <- connectPostgreSQL connectInfo
    dbConn2 <- connectPostgreSQL connectInfo
    dbConn3 <- connectPostgreSQL connectInfo
    fetState <- readBitcoindStateFromDB dbConn1 >>= \s
                    -> return $ updateMarkerAddresses s maConfig
    let streamSettings = MtGoxStreamSettings
                            DisableWalletNotifications SkipFullDepth
    mtgoxHandles <- initMtGoxAPI (Just watchdogLogger)
                                    (bcMtGoxCredentials bwConfig)
                                    streamSettings
    mtgoxFee <- do
        privateInfoM <- callHTTPApi mtgoxHandles getPrivateInfoR
        case privateInfoM of
            Nothing -> error "Unable to determine current Mt.Gox fee"
            Just privateInfo -> return $ piFee privateInfo
    fetStateCopy <- newMVar fetState
    fbetHandle <- initFilteredBitcoinEventTask (Just watchdogLogger)
                    (bcRPCAuth bwConfig) (bcNotifyFile bwConfig)
                    acceptAfterThreeConfs fetState
    rbHandle <- initRebalancer appLogger (Just watchdogLogger)
                                    (bcRPCAuth bwConfig) mtgoxHandles
                                    (bcSafetyMarginBTC bwConfig)
    patHandleMVar <- newEmptyMVar
    _ <- forkIO $ periodicRebalancing rbHandle
    let preliminaryBWHandles =
            BridgewalkerHandles { bhLoggingHandle = lHandle
                                , bhAppLogger = appLogger
                                , bhWatchdogLogger = watchdogLogger
                                , bhConfig = bwConfig
                                , bhDBConnPAT = dbConn1
                                , bhDBConnCH = dbConn2
                                , bhDBConnFBET = dbConn3
                                , bhMtGoxHandles = mtgoxHandles
                                , bhMtGoxFee = mtgoxFee
                                , bhFilteredBitcoinEventTaskHandle = fbetHandle
                                , bhFilteredEventStateCopy = fetStateCopy
                                , bhRebalancerHandle = rbHandle
                                , bhClientHubHandle =
                                    error "ClientHub was accessed,\
                                          \ but not initialized yet."
                                , bhPendingActionsTrackerHandleMVar
                                    = patHandleMVar
                                }
    chHandle <- initClientHub preliminaryBWHandles
    let bwHandles = preliminaryBWHandles { bhClientHubHandle = chHandle }
    patHandle <- initPendingActionsTracker bwHandles
    putMVar patHandleMVar patHandle
    _ <- forkIO $ periodicNudging patHandle
    return bwHandles
  where
    adapt :: Logger -> WatchdogLogger
    adapt logger taskErr delay =
        let logMsg = WatchdogError
                        { lcInfo = formatWatchdogError taskErr delay }
        in logger logMsg

justCatchUp :: BridgewalkerHandles -> IO ()
justCatchUp bwHandles =
    let fbetHandle = bhFilteredBitcoinEventTaskHandle bwHandles
        dbConn = bhDBConnFBET bwHandles
    in forever $ do
        (fetState, _) <- waitForFilteredBitcoinEvents fbetHandle
        writeBitcoindStateToDB dbConn fetState

tryToSellBtc :: MtGoxAPIHandles -> Integer -> BitcoinAmount -> IO (Either String OrderStats)
tryToSellBtc mtgoxHandles safetyMargin amount = runEitherT $ do
    privateInfo <- noteT "Unable to call getPrivateInfoR"
                    . MaybeT $ callHTTPApi mtgoxHandles getPrivateInfoR
    _ <- tryAssert "Not enough funds available at MtGox to sell BTC"
            (piBtcBalance privateInfo >= adjustAmount amount + safetyMargin)
    orderStats <- EitherT $
        callHTTPApi mtgoxHandles submitOrder
            OrderTypeSellBTC (adjustAmount amount)
    return orderStats

displayStats :: OrderStats -> IO ()
displayStats stats =
    let usd = fromIntegral (usdEarned stats) / (10 ^ (5 :: Integer))
    in putStrLn $ "Account activity: + $" ++ show usd

actOnDeposits :: BridgewalkerHandles -> IO ()
actOnDeposits bwHandles = do
    let fbetHandle = bhFilteredBitcoinEventTaskHandle bwHandles
        fetStateCopy = bhFilteredEventStateCopy bwHandles
        dbConn = bhDBConnFBET bwHandles
        patHandleMVar = bhPendingActionsTrackerHandleMVar bwHandles
        chHandle = bhClientHubHandle bwHandles
    patHandle <- readMVar patHandleMVar
    forever $ do
        (fetState, fEvents) <- waitForFilteredBitcoinEvents fbetHandle
        mapM_ print fEvents
        let actions = concatMap convertToActions fEvents
        withTransaction dbConn $ do     -- atomic transaction: do not update
                                        -- fetState, before recording necessary
                                        -- actions to be done as a result
            addPendingActions dbConn actions
            writeBitcoindStateToDB dbConn fetState
            _ <- swapMVar fetStateCopy fetState
            return ()
        unless (null actions) $ nudgePendingActionsTracker patHandle
        signalPossibleBitcoinEvents chHandle
  where
    convertToActions fTx@FilteredNewTransaction{} =
        let amount = adjustAmount . tAmount . fntTx $ fTx
            address = tAddress . fntTx $ fTx
        in [DepositAction { baAmount = amount, CT.baAddress = address }]
    convertToActions _ = []

initBridgewalker :: IO BridgewalkerHandles
initBridgewalker = do
    bwHandles <- initBridgewalkerHandles myConnectInfo
    _ <- forkIO $ actOnDeposits bwHandles
    return bwHandles

-- TODO: Find bug - either: something related to standard transactions
--                      or: something related to marker transactions, that
--                            confirm while the application is not running
--                            (update: seems not to be the case)
--                      or: a combination of these (?)
--                      ---> try to design a unit test that involves shutting
--                      down and restarting from database after each step
