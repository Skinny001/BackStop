// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {IBackstopRegistry} from "../src/interfaces/IBackstopRegistry.sol";
import {IInsuranceVault} from "../src/interfaces/IInsuranceVault.sol";

/// @notice A minimal, purpose-built demo router. Deployed once per demo "actor" (searcher,
///         victim, LP) so each has its own distinct on-chain address — this address is what
///         BackstopHook sees as `sender` (see ARCHITECTURE_VALIDATION.md #1) and what PoolManager
///         records as a liquidity position's `owner`, and is therefore also the identity that
///         must hold the bond / call `claim()`. `PoolSwapTest`/`PoolModifyLiquidityTest`
///         (v4-core's own test routers) have no bonding or claiming capability and — critically
///         for claiming — using two *different* router instances for adding liquidity and for
///         claiming would silently claim on the wrong position owner. This router does swap,
///         bond, add-liquidity, and claim all as the *same* address so the demo script's LP step
///         actually pays out.
contract DemoRouter is IUnlockCallback {
    IPoolManager public immutable manager;
    IBackstopRegistry public immutable registry;
    IInsuranceVault public immutable vault;
    address public immutable operator;
    /// @notice Optional bundler address (e.g. Bundler.sol) additionally allowed to call `swap`.
    ///         Bonding/liquidity/claim stay operator-only — only the swap legs of a sandwich
    ///         demo need to be nested inside one real transaction (see Demo.s.sol / Bundler.sol
    ///         for why calling `swap` three times as three separate top-level broadcast
    ///         transactions does NOT reproduce the same-transaction pattern on a real chain).
    address public immutable bundler;

    enum Action {
        Swap,
        ModifyLiquidity
    }

    struct CallbackData {
        Action action;
        address payer;
        PoolKey key;
        IPoolManager.SwapParams swapParams;
        IPoolManager.ModifyLiquidityParams liqParams;
    }

    modifier onlyOperator() {
        require(msg.sender == operator, "not operator");
        _;
    }

    constructor(
        IPoolManager _manager,
        IBackstopRegistry _registry,
        IInsuranceVault _vault,
        address _operator,
        address _bundler
    ) {
        manager = _manager;
        registry = _registry;
        vault = _vault;
        operator = _operator;
        bundler = _bundler;
    }

    /// @notice Pulls `amount` of `token` from the operator and bonds it under THIS router's own
    ///         address (the identity that will also perform swaps below).
    function bond(IERC20Minimal token, uint256 amount) external onlyOperator {
        require(token.transferFrom(msg.sender, address(this), amount), "transferFrom failed");
        require(token.approve(address(registry), amount), "approve failed");
        registry.deposit(amount);
    }

    /// @notice Performs one swap with this router as PoolManager's `sender`. Any outstanding
    ///         debt is pulled from the operator (who must have approved this router).
    function swap(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        external
        returns (BalanceDelta)
    {
        require(msg.sender == operator || msg.sender == bundler, "not authorized");
        IPoolManager.ModifyLiquidityParams memory empty;
        return abi.decode(
            manager.unlock(abi.encode(CallbackData(Action.Swap, msg.sender, key, params, empty))), (BalanceDelta)
        );
    }

    /// @notice Adds/removes liquidity with this router as the recorded position `owner`.
    function modifyLiquidity(PoolKey calldata key, IPoolManager.ModifyLiquidityParams calldata params)
        external
        onlyOperator
        returns (BalanceDelta)
    {
        IPoolManager.SwapParams memory empty;
        return abi.decode(
            manager.unlock(abi.encode(CallbackData(Action.ModifyLiquidity, msg.sender, key, empty, params))),
            (BalanceDelta)
        );
    }

    /// @notice Claims this router's own accrued insurance entitlement and forwards it to the
    ///         operator's own ERC-6909 claim balance in one call.
    function claim(PoolId poolId, Currency currency0, Currency currency1, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        onlyOperator
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1) = vault.claim(poolId, currency0, currency1, tickLower, tickUpper, salt);
        if (amount0 > 0) manager.transfer(msg.sender, currency0.toId(), amount0);
        if (amount1 > 0) manager.transfer(msg.sender, currency1.toId(), amount1);
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        CallbackData memory d = abi.decode(rawData, (CallbackData));

        if (d.action == Action.Swap) {
            BalanceDelta delta = manager.swap(d.key, d.swapParams, "");
            _settle(d.key.currency0, delta.amount0(), d.payer);
            _settle(d.key.currency1, delta.amount1(), d.payer);
            return abi.encode(delta);
        } else {
            (BalanceDelta delta,) = manager.modifyLiquidity(d.key, d.liqParams, "");
            _settle(d.key.currency0, delta.amount0(), d.payer);
            _settle(d.key.currency1, delta.amount1(), d.payer);
            return abi.encode(delta);
        }
    }

    function _settle(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            manager.sync(currency);
            require(
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), uint256(uint128(-amount))),
                "settle transferFrom failed"
            );
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}
