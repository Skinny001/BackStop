// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopTestBase} from "../utils/BackstopTestBase.sol";

/// @notice Sanity check that the harness itself (real PoolManager, mined hook, direct-unlock
///         liquidity, two independent router identities) wires up correctly before layering the
///         actual sandwich-pattern test cases on top of it.
contract SetupTest is BackstopTestBase {
    function test_harness_deploysAndInitializesPool() public view {
        assertTrue(address(hook).code.length > 0);
        assertTrue(registry.hook() == address(hook));
        assertTrue(vault.hook() == address(hook));
    }
}
