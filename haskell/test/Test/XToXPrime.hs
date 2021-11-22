-- SPDX-FileCopyrightText: 2021 Arthur Breitman
-- SPDX-License-Identifier: LicenseRef-MIT-Arthur-Breitman

{-# OPTIONS_GHC -Wno-missing-export-lists #-}

module Test.XToXPrime
  ( test_swapping_x_for_x_prime
  , test_fails_when_y_doesnt_match
  ) where

import Prelude

import Hedgehog hiding (assert, failure)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Lorentz hiding (assert, not, now, (>>))
import qualified Lorentz.Contracts.Spec.FA2Interface as FA2
import Morley.Nettest
import Morley.Nettest.Tasty
import Test.Tasty (TestTree)
import Test.Tasty.Hedgehog (testProperty)

import SegCFMM.Types
import Test.Invariants
import Test.Math
import Test.Util

test_swapping_x_for_x_prime :: TestTree
test_swapping_x_for_x_prime =
  testProperty "allows swapping X for X'" $ property do
    let liquidity = 1_e7
    let lowerTickIndex = -1000
    let upperTickIndex = 1000

    dx <- forAll $ Gen.integral (Range.linear 0 300_000)
    feeBps1 <- forAll $ Gen.integral (Range.linear 0 10_000)
    feeBps2 <- forAll $ Gen.integral (Range.linear 0 10_000)

    clevelandProp do
      liquidityProvider <- newAddress auto
      swapper <- newAddress auto
      swapReceiver <- newAddress auto
      let accounts = [liquidityProvider, swapper]

      (x, y, z) <- forEach (FA2.TokenId 0, FA2.TokenId 1, FA2.TokenId 2) $ originateFA2 accounts

      (cfmm1, _) <- prepareSomeSegCFMM' accounts (Just (x, y)) Nothing (set cFeeBpsL feeBps1)
      (cfmm2, _) <- prepareSomeSegCFMM' accounts (Just (z, y)) Nothing (set cFeeBpsL feeBps2)

      for_ [cfmm1, cfmm2] \cfmm -> do
        withSender liquidityProvider $ setPosition cfmm liquidity (lowerTickIndex, upperTickIndex)

      initialSt1 <- getFullStorage cfmm1
      initialSt2 <- getFullStorage cfmm2
      initialBalanceSwapperX <- balanceOf x swapper
      initialBalanceSwapperY <- balanceOf y swapper
      initialBalanceSwapperZ <- balanceOf z swapper
      initialBalanceSwapReceiverX <- balanceOf x swapReceiver
      initialBalanceSwapReceiverY <- balanceOf y swapReceiver
      initialBalanceSwapReceiverZ <- balanceOf z swapReceiver

      withSender swapper do
        call cfmm1 (Call @"X_to_x_prime") XToXPrimeParam
          { xppDx = dx
          , xppX_PrimeContract = toAddress cfmm2
          , xppDeadline = validDeadline
          , xppMinDxPrime = 0
          , xppToDxPrime = swapReceiver
          }
      checkAllInvariants cfmm1
      checkAllInvariants cfmm2

      finalBalanceSwapperX <- balanceOf x swapper
      finalBalanceSwapperY <- balanceOf y swapper
      finalBalanceSwapperZ <- balanceOf z swapper
      finalBalanceSwapReceiverX <- balanceOf x swapReceiver
      finalBalanceSwapReceiverY <- balanceOf y swapReceiver
      finalBalanceSwapReceiverZ <- balanceOf z swapReceiver

      let expectedFee1 = calcSwapFee feeBps1 dx
      let expectedNewPrice1 = calcNewPriceX (sSqrtPrice initialSt1) (sLiquidity initialSt1) (dx - expectedFee1)
      let expectedDy = fromIntegral @Integer @Natural $ receivedY (sSqrtPrice initialSt1) (adjustScale @80 expectedNewPrice1) (sLiquidity initialSt1)
      let expectedFee2 = calcSwapFee feeBps2 expectedDy
      let expectedNewPrice2 = calcNewPriceY (sSqrtPrice initialSt2) (sLiquidity initialSt2) (expectedDy - expectedFee2)
      let expectedDz = fromIntegral @Integer @Natural $ receivedX (sSqrtPrice initialSt2) (adjustScale @80 expectedNewPrice2) (sLiquidity initialSt2)

      finalBalanceSwapperX @== initialBalanceSwapperX - dx
      finalBalanceSwapperY @== initialBalanceSwapperY
      finalBalanceSwapperZ @== initialBalanceSwapperZ
      finalBalanceSwapReceiverX @== initialBalanceSwapReceiverX
      finalBalanceSwapReceiverY @== initialBalanceSwapReceiverY
      -- Allow a rounding error of 1 token
      finalBalanceSwapReceiverZ `isInRangeNat` (initialBalanceSwapReceiverZ + expectedDz) $ (1, 1)


test_fails_when_y_doesnt_match :: TestTree
test_fails_when_y_doesnt_match =
  nettestScenarioOnEmulatorCaps "fails when the 2 contracts have different Y tokens" do
    let liquidity = 1_e7
    let lowerTickIndex = -1000
    let upperTickIndex = 1000

    liquidityProvider <- newAddress auto
    swapper <- newAddress auto
    swapReceiver <- newAddress auto
    let accounts = [liquidityProvider, swapper]

    (cfmm1, _) <- prepareSomeSegCFMM accounts
    (cfmm2, _) <- prepareSomeSegCFMM accounts

    for_ [cfmm1, cfmm2] \cfmm -> do
      withSender liquidityProvider $ setPosition cfmm liquidity (lowerTickIndex, upperTickIndex)

    withSender swapper do
      call cfmm1 (Call @"X_to_x_prime") XToXPrimeParam
        { xppDx = 10
        , xppX_PrimeContract = toAddress cfmm2
        , xppDeadline = validDeadline
        , xppMinDxPrime = 0
        , xppToDxPrime = swapReceiver
        }
        & expectCustomError_ #fA2_NOT_OPERATOR
