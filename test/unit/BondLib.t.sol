// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {BondLib} from "../../src/libraries/BondLib.sol";
import {BackstopConfig} from "../../src/types/BackstopTypes.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";

contract BondLibTest is Test {
    function test_gasPremium_saturatesAtZero() public pure {
        assertEq(BondLib.gasPremium(5, 10), 0); // gasPrice <= baseFee
        assertEq(BondLib.gasPremium(10, 10), 0);
        assertEq(BondLib.gasPremium(15, 10), 5);
    }

    function test_computeTax_flatFloorApplies() public pure {
        BackstopConfig memory c = BackstopConfig({
            priorityTaxBps: 1000,
            minFlatTax: 100,
            maxTax: 1000,
            minDisplacementBps: 0,
            minVictimNotional: 0,
            minReversalBps: 0,
            slashBps: 0
        });
        // premium = 0 (gasPrice <= baseFee) => raw tax 0, floored to minFlatTax
        assertEq(BondLib.computeTax(5, 10, c), 100);
    }

    function test_computeTax_capApplies() public pure {
        BackstopConfig memory c = BackstopConfig({
            priorityTaxBps: 10_000, // 100%
            minFlatTax: 0,
            maxTax: 50,
            minDisplacementBps: 0,
            minVictimNotional: 0,
            minReversalBps: 0,
            slashBps: 0
        });
        // premium = 1000, tax = 1000 uncapped, capped to 50
        assertEq(BondLib.computeTax(1010, 10, c), 50);
    }

    function test_computeSlash_neverExceedsBond() public pure {
        assertEq(BondLib.computeSlash(100, 10_000), 100); // 100% of 100
        assertEq(BondLib.computeSlash(100, 5000), 50);
        assertEq(BondLib.computeSlash(0, 10_000), 0);
    }

    /// @dev gasPrice/baseFee bounded to realistic magnitudes (uint64 ~ 1.8e19 wei) — unlike
    ///      `computeSlash`'s bond-at-risk argument, there is no natural "100%" cap to clamp a raw
    ///      gas price to, so this documents the assumption instead of engineering around it.
    function testFuzz_computeTax_alwaysWithinBounds(
        uint64 gasPrice,
        uint64 baseFee,
        uint16 priorityTaxBps,
        uint128 minFlatTax,
        uint128 maxTaxRaw
    ) public pure {
        uint128 maxTax = uint128(bound(maxTaxRaw, minFlatTax, type(uint128).max));
        BackstopConfig memory c = BackstopConfig({
            priorityTaxBps: priorityTaxBps,
            minFlatTax: minFlatTax,
            maxTax: maxTax,
            minDisplacementBps: 0,
            minVictimNotional: 0,
            minReversalBps: 0,
            slashBps: 0
        });
        uint128 tax = BondLib.computeTax(gasPrice, baseFee, c);
        assertGe(tax, c.minFlatTax);
        assertLe(tax, c.maxTax);
    }

    /// @dev Fully unbounded — `computeSlash` uses `FullMath.mulDiv` internally specifically so it
    ///      holds for the entire `uint256` domain, not just realistic bond sizes.
    function testFuzz_computeSlash_neverExceedsBondOrBps(uint256 bond, uint16 slashBps) public pure {
        uint256 slashed = BondLib.computeSlash(bond, slashBps);
        assertLe(slashed, bond);
        uint256 clampedBps = slashBps > 10_000 ? 10_000 : slashBps;
        assertEq(slashed, FullMath.mulDiv(bond, clampedBps, 10_000));
    }
}
