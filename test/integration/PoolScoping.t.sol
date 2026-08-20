// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopTestBase} from "../utils/BackstopTestBase.sol";
import {IBackstopHook} from "../../src/interfaces/IBackstopHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {CustomRevert} from "v4-core/libraries/CustomRevert.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

/// @notice A hook address's permission bits aren't bound to any one pool (see
///         ARCHITECTURE_VALIDATION.md #7/#9) — proves BackstopHook actually refuses to run its
///         logic against any pool other than the one it was constructed for, rather than relying
///         on nobody ever initializing a second pool with the same address.
contract PoolScopingTest is BackstopTestBase {
    function test_secondPoolWithSameHook_swapReverts() public {
        // Same currencies, different fee tier => a different, valid PoolId, same hook address.
        PoolKey memory otherKey =
            PoolKey(key.currency0, key.currency1, 500, 10, IHooks(address(hook)));
        manager.initialize(otherKey, TickMath.getSqrtPriceAtTick(0));

        // PoolManager wraps a reverting hook call in CustomRevert.WrappedError rather than
        // bubbling the raw selector to the top level — assert on the actual wrapped shape so
        // this test still proves BackstopHook.WrongPool is what fired, not just "something did."
        vm.prank(searcherEOA);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeSwap.selector,
                abi.encodeWithSelector(IBackstopHook.WrongPool.selector),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        routerA.swap(
            otherKey,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(1e18),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
