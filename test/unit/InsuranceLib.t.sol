// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {InsuranceLib} from "../../src/libraries/InsuranceLib.sol";
import {FixedPoint128} from "v4-core/libraries/FixedPoint128.sol";

contract InsuranceLibTest is Test {
    function test_growthIncrement_basic() public pure {
        // 100 tokens spread over 100 liquidity => 1 token per unit => growth = 1 * Q128
        uint256 g = InsuranceLib.growthIncrement(100, 100);
        assertEq(g, FixedPoint128.Q128);
    }

    function test_entitlement_matchesGrowthIncrement_roundTrip() public pure {
        uint128 liquidity = 100;
        uint256 g = InsuranceLib.growthIncrement(100, liquidity);
        uint256 e = InsuranceLib.entitlement(liquidity, g, 0);
        // Round-trips exactly for this clean ratio.
        assertEq(e, 100);
    }

    function test_entitlement_zeroWhenNoNewGrowth() public pure {
        assertEq(InsuranceLib.entitlement(1000, 5e30, 5e30), 0);
        assertEq(InsuranceLib.entitlement(1000, 4e30, 5e30), 0); // stale/negative delta guarded to 0
    }

    /// A payout spread over the pool's liquidity, then claimed in full by a single LP owning
    /// 100% of that liquidity, must recover (up to rounding-down dust) the original payout —
    /// this is the core "no value created or destroyed" property of the growth-index model.
    function testFuzz_conservation_singleLpOwnsAllLiquidity(uint256 payout, uint128 liquidity) public pure {
        liquidity = uint128(bound(liquidity, 1, type(uint128).max));
        payout = bound(payout, 0, type(uint128).max); // keep payout*Q128 from overflowing mulDiv's internal 512-bit math headroom for this test's own arithmetic below
        uint256 growth = InsuranceLib.growthIncrement(payout, liquidity);
        uint256 recovered = InsuranceLib.entitlement(liquidity, growth, 0);
        // Integer division rounds down at most once each way; recovered is never more than paid,
        // and never short by more than a negligible rounding dust bounded by `liquidity`.
        assertLe(recovered, payout);
        assertLe(payout - recovered, liquidity == 0 ? 0 : 1);
    }

    /// Two LPs splitting a pool's liquidity should recover, between them, no more than the
    /// original payout in total (conservation under partial ownership).
    function testFuzz_conservation_twoLpsSplitLiquidity(uint256 payout, uint128 liqA, uint128 liqB) public pure {
        liqA = uint128(bound(liqA, 1, type(uint128).max / 2));
        liqB = uint128(bound(liqB, 1, type(uint128).max / 2));
        payout = bound(payout, 0, type(uint128).max);
        uint128 total = liqA + liqB;
        uint256 growth = InsuranceLib.growthIncrement(payout, total);
        uint256 eA = InsuranceLib.entitlement(liqA, growth, 0);
        uint256 eB = InsuranceLib.entitlement(liqB, growth, 0);
        assertLe(eA + eB, payout);
    }
}
