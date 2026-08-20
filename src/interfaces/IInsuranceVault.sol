// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";

interface IInsuranceVault {
    event Funded(PoolId indexed poolId, Currency indexed currency, uint256 amount, uint256 newGrowthX128);
    event Claimed(PoolId indexed poolId, address indexed lp, Currency indexed currency, uint256 amount);

    error NotHook();
    error ZeroLiquidity();
    error NotDeployer();
    error HookAlreadySet();

    /// @notice Records a payout of `amount` of `currency` into pool `poolId`'s growth index,
    ///         spread over the pool's current active liquidity. Callable only by the hook.
    ///         Assumes `amount` of PoolManager ERC-6909 claims for `currency` have already been
    ///         minted to this vault in the same call (see BackstopHook `_settle`).
    function fund(PoolId poolId, Currency currency, uint256 amount, uint128 activeLiquidity) external;

    /// @notice Claims the caller's accrued, unclaimed entitlement for one position in one pool,
    ///         in both pool currencies, transferring ERC-6909 claim balance to the caller.
    function claim(PoolId poolId, Currency currency0, Currency currency1, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        returns (uint256 amount0, uint256 amount1);

    /// @notice Force-checkpoints `owner`'s position before a liquidity change, so growth accrued
    ///         before the change cannot be claimed against post-change liquidity. Callable only
    ///         by the hook (invoked from beforeAddLiquidity/beforeRemoveLiquidity).
    function checkpoint(
        PoolId poolId,
        Currency currency0,
        Currency currency1,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 currentLiquidity
    ) external;
}
