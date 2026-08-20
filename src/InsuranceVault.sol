// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IInsuranceVault} from "./interfaces/IInsuranceVault.sol";
import {InsuranceLib} from "./libraries/InsuranceLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

/// @title InsuranceVault
/// @notice Holds slash/tax proceeds as PoolManager ERC-6909 claim balances and spreads them
///         across LPs via a growth-per-liquidity-unit accumulator, exactly mirroring Uniswap's
///         own feeGrowthGlobal/feeGrowthInside mechanism (see ARCHITECTURE_VALIDATION.md #6).
///         LP payout is "automatic entitlement creation," not a same-instruction physical
///         transfer to every LP — claiming is a separate, LP-initiated, O(1) pull.
/// @dev Never calls PoolManager's onlyWhenUnlocked functions (mint/take/burn/settle/sync) —
///      `claim` only reads state and moves the vault's own already-minted ERC-6909 balance via
///      the unrestricted `transfer` function (see ARCHITECTURE_VALIDATION.md #4).
contract InsuranceVault is IInsuranceVault {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    address private immutable deployer;
    address public hook;

    /// @notice Cumulative payout-per-liquidity-unit, Q128, per pool per currency. Monotonic.
    mapping(PoolId => mapping(Currency => uint256)) public rewardGrowthX128;

    /// @notice Each position's last-seen growth value, per currency.
    mapping(PoolId => mapping(bytes32 => mapping(Currency => uint256))) public checkpointGrowthX128;

    /// @notice Entitlement banked at checkpoint time (before a liquidity change) that has not
    ///         yet been claimed — mirrors Uniswap's Position.tokensOwed.
    mapping(PoolId => mapping(bytes32 => mapping(Currency => uint256))) public owed;

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address poolManager_) {
        poolManager = IPoolManager(poolManager_);
        deployer = msg.sender;
    }

    /// @notice One-time wiring of the authorized hook address (see BackstopRegistry.setHook for
    ///         why this can't just be a constructor argument).
    function setHook(address hook_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
    }

    /// @inheritdoc IInsuranceVault
    function fund(PoolId poolId, Currency currency, uint256 amount, uint128 activeLiquidity) external onlyHook {
        if (activeLiquidity == 0) revert ZeroLiquidity();
        uint256 increment = InsuranceLib.growthIncrement(amount, activeLiquidity);
        uint256 newGrowth = rewardGrowthX128[poolId][currency] + increment;
        rewardGrowthX128[poolId][currency] = newGrowth;
        emit Funded(poolId, currency, amount, newGrowth);
    }

    /// @inheritdoc IInsuranceVault
    function checkpoint(
        PoolId poolId,
        Currency currency0,
        Currency currency1,
        address owner,
        int24 tickLower,
        int24 tickUpper,
        bytes32 salt,
        uint128 currentLiquidity
    ) external onlyHook {
        bytes32 positionKey = Position.calculatePositionKey(owner, tickLower, tickUpper, salt);
        _bank(poolId, positionKey, currency0, currentLiquidity);
        _bank(poolId, positionKey, currency1, currentLiquidity);
    }

    /// @inheritdoc IInsuranceVault
    function claim(PoolId poolId, Currency currency0, Currency currency1, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        bytes32 positionKey = Position.calculatePositionKey(msg.sender, tickLower, tickUpper, salt);
        uint128 liquidity = poolManager.getPositionLiquidity(poolId, positionKey);

        _bank(poolId, positionKey, currency0, liquidity);
        _bank(poolId, positionKey, currency1, liquidity);

        amount0 = _payOut(poolId, positionKey, currency0);
        amount1 = _payOut(poolId, positionKey, currency1);
    }

    /// @dev Rolls any newly-accrued growth (computed with the liquidity the position held up to
    ///      *this* moment) into `owed`, and advances the checkpoint. Called both from `claim`
    ///      (liquidity = current on-chain liquidity) and from `checkpoint` (liquidity = the
    ///      pre-change amount the hook read before a modifyLiquidity call lands) — see
    ///      MECHANISM.md "Checkpoint invariant" for why this must happen before any liquidity
    ///      change, not just at claim time.
    function _bank(PoolId poolId, bytes32 positionKey, Currency currency, uint128 liquidity) private {
        uint256 currentGrowth = rewardGrowthX128[poolId][currency];
        uint256 last = checkpointGrowthX128[poolId][positionKey][currency];
        if (currentGrowth == last) return;
        uint256 pending = InsuranceLib.entitlement(liquidity, currentGrowth, last);
        if (pending > 0) owed[poolId][positionKey][currency] += pending;
        checkpointGrowthX128[poolId][positionKey][currency] = currentGrowth;
    }

    /// @dev Pays out `owed`, capped at the vault's actual claim balance for that currency — if
    ///      the vault is short (should not happen given funding-at-settlement, but is defended
    ///      against per MECHANISM.md "Failure modes"), the shortfall remains in `owed` for a
    ///      future claim rather than reverting the whole call.
    function _payOut(PoolId poolId, bytes32 positionKey, Currency currency) private returns (uint256 paid) {
        uint256 pending = owed[poolId][positionKey][currency];
        if (pending == 0) return 0;
        uint256 available = poolManager.balanceOf(address(this), currency.toId());
        paid = pending > available ? available : pending;
        if (paid == 0) return 0;
        owed[poolId][positionKey][currency] = pending - paid;
        poolManager.transfer(msg.sender, currency.toId(), paid);
        emit Claimed(poolId, msg.sender, currency, paid);
    }
}
