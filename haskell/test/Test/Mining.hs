-- SPDX-FileCopyrightText: 2021 Arthur Breitman
-- SPDX-License-Identifier: LicenseRef-MIT-Arthur-Breitman

-- | Tests on our liquidity mining demo contract.
module Test.Mining
  ( test_BasicWorkflow
  ) where

import Universum

import Test.Tasty (TestTree)

import Lorentz.Coercions
import Lorentz.Value
import Morley.Nettest
import Morley.Nettest.Tasty
import Tezos.Core

import qualified Lorentz.Contracts.Spec.FA2Interface as FA2

import Cleveland.Util
import FA2.Types
import LiquidityMining.Types
import qualified SegCFMM.Types as CFMM
import Test.LiquidityMining.Contract
import Test.Util

theConfig :: Config
theConfig = Config
  { cMaxIncentiveStartLeadTime = 1000000
  , cMaxIncentiveDuration = 1000000
  }

mkStorage :: ContractHandler CFMM.Parameter cfmmStorage -> Storage
mkStorage = initStorage theConfig . toTAddress

test_BasicWorkflow :: TestTree
test_BasicWorkflow =
  forAllTokenTypeCombinations "Basic workflow works" \tokenTypes ->
  nettestScenarioOnEmulatorCaps (show tokenTypes) do

    -- Actors
    rewardGiver <- newAddress "reward-keeper"
    liquidityProvider <- newAddress "liquidity-provider"

    -- Prepare token with reward
    let miningRewardTokenId = FA2.TokenId 10
    miningRewardTokenContract <- originateFA2 [rewardGiver] miningRewardTokenId
    let miningRewardToken = FA2Token (toAddress miningRewardTokenContract) miningRewardTokenId
    rewardBalanceConsumer <- originateBalanceConsumer (TokenInfo miningRewardTokenId miningRewardTokenContract)
    let getRewardOf = balanceOf rewardBalanceConsumer

    -- Prepare the contracts
    (cfmm, _) <- prepareSomeSegCFMM [liquidityProvider] tokenTypes def
    staker <- originateSimple "LM" (mkStorage cfmm) liquidityMiningContract

    -- Step I: incentive creation
    (incentiveId, incentiveRefundee) <- do
      refundee <- newAddress "incentive-refundee"
      now <- getNow
      withSender rewardGiver do
        call miningRewardTokenContract (Call @"Update_operators")
          [FA2.AddOperator $ FA2.OperatorParam rewardGiver (toAddress staker) miningRewardTokenId]
        call staker (Call @"Create_incentive") IncentiveParams
          { ipRewardToken = miningRewardToken
          , ipTotalReward = 100
          , ipStartTime = now `timestampPlusSeconds` 5
          , ipEndTime = now `timestampPlusSeconds` 105
          , ipRefundee = refundee
          }
      let incentiveId = IncentiveId 0
      return (incentiveId, refundee)

    -- Step II: registering deposit
    let lowerTickIndex = CFMM.TickIndex (-100)
    let upperTickIndex = CFMM.TickIndex 100
    positionId <- do

      withSender liquidityProvider do
        setPosition cfmm 10 (lowerTickIndex, upperTickIndex)
        let positionId = CFMM.PositionId 0

        updateOperator cfmm liquidityProvider (toAddress staker) (checkedCoerce positionId) True

        call staker (Call @"Register_deposit") positionId
        return positionId

    -- Wait for incentive start
    advanceTime (sec 5)

    -- Step III: staking
    withSender liquidityProvider do
      call staker (Call @"Stake_token") (incentiveId, positionId)

    -- Keep stake at active position for 1/5 of the time
    advanceTime (sec 20)

    -- Step IV: unstaking
    withSender liquidityProvider do
      call staker (Call @"Unstake_token") (incentiveId, positionId)

    -- Step V: obtaining reward
    withSender liquidityProvider do
      rewardReceiver <- newAddress "reward-receiver"
      call staker (Call @"Claim_reward")
        (miningRewardToken, rewardReceiver, Nothing)

      getRewardOf rewardReceiver @@== 20
      -- ↑ getting 1/5 of 100 reward

    -- Closing stuff
    withSender liquidityProvider do
      call staker (Call @"Withdraw_deposit") (positionId, liquidityProvider)

    advanceTime (sec 100)
    call staker (Call @"End_incentive") incentiveId
    getRewardOf incentiveRefundee @@== 80
