// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {Position} from "v4-core/libraries/Position.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {IBackstopHook} from "./interfaces/IBackstopHook.sol";
import {BackstopRegistry} from "./BackstopRegistry.sol";
import {InsuranceVault} from "./InsuranceVault.sol";
import {AttributionLib} from "./libraries/AttributionLib.sol";
import {PredicateLib} from "./libraries/PredicateLib.sol";
import {BondLib} from "./libraries/BondLib.sol";
import {BackstopConfig, PredicateResult} from "./types/BackstopTypes.sol";

/// @title BackstopHook
/// @notice A Uniswap v4 hook that charges a priority tax on bonded/enrolled searchers and slashes
///         their bond into an LP insurance reserve when their own swaps, within a single
///         transaction, match a narrowly-defined displacement-and-reversal pattern around another
///         party's swap. See MECHANISM.md for the full model and ARCHITECTURE_VALIDATION.md for
///         why each design decision below is what it is, not what the original brief assumed.
/// @dev Scoped to exactly one protected pool, computed at construction time (see
///      ARCHITECTURE_VALIDATION.md #6 / MECHANISM.md "Bond/insurance currency mismatch" for why
///      the bond asset must be one of that pool's two currencies).
contract BackstopHook is IHooks, IBackstopHook {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;
    BackstopRegistry public immutable registry;
    InsuranceVault public immutable vault;

    Currency public immutable currency0;
    Currency public immutable currency1;
    Currency public immutable bondCurrency;
    PoolId public immutable protectedPoolId;

    address public owner;
    BackstopConfig public config;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev A hook address's permission bits are not bound to any one pool — anyone could
    ///      initialize a *different* pool (different currencies/fee) reusing this same deployed
    ///      hook address. Backstop is deliberately single-pool-scoped (see MECHANISM.md "Bond/
    ///      insurance currency mismatch"), so every callback must reject any pool other than the
    ///      one this hook was constructed for.
    modifier onlyProtectedPool(PoolId poolId) {
        if (PoolId.unwrap(poolId) != PoolId.unwrap(protectedPoolId)) revert WrongPool();
        _;
    }

    constructor(
        IPoolManager _poolManager,
        BackstopRegistry _registry,
        InsuranceVault _vault,
        Currency _currency0,
        Currency _currency1,
        uint24 _fee,
        int24 _tickSpacing,
        Currency _bondCurrency,
        address _owner,
        BackstopConfig memory _config
    ) {
        if (!(_bondCurrency == _currency0 || _bondCurrency == _currency1)) revert BondAssetNotInPool();
        _validateConfig(_config);

        poolManager = _poolManager;
        registry = _registry;
        vault = _vault;
        currency0 = _currency0;
        currency1 = _currency1;
        bondCurrency = _bondCurrency;
        owner = _owner;
        config = _config;

        PoolKey memory key = PoolKey(_currency0, _currency1, _fee, _tickSpacing, IHooks(address(this)));
        protectedPoolId = key.toId();

        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function setConfig(BackstopConfig calldata newConfig) external onlyOwner {
        _validateConfig(newConfig);
        config = newConfig;
        emit ConfigUpdated(newConfig);
    }

    /// @dev `maxTax` is bounded well below `type(int128).max` so `int128(tax)` in `beforeSwap`
    ///      can never truncate/overflow — a misconfiguration safety rail, not a normal-operation
    ///      concern (tax amounts are meant to be small relative to swap sizes).
    function _validateConfig(BackstopConfig memory c) internal pure {
        require(c.minFlatTax <= c.maxTax, "minFlatTax > maxTax");
        require(c.maxTax <= uint128(type(int128).max), "maxTax too large");
        require(c.slashBps <= 10_000, "slashBps > 100%");
        require(c.minDisplacementBps <= 10_000, "minDisplacementBps > 100%");
        require(c.minReversalBps <= 10_000, "minReversalBps > 100%");
    }

    // ---------------------------------------------------------------------
    // IHooks — swap callbacks
    // ---------------------------------------------------------------------

    function beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        onlyPoolManager
        onlyProtectedPool(key.toId())
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        BackstopConfig memory cfg = config;

        // Snapshot the price this swap will move from, for use by our own afterSwap call below.
        (uint160 sqrtPriceBeforeX96,,,) = poolManager.getSlot0(poolId);
        AttributionLib.stashPreSwapPrice(poolId, sqrtPriceBeforeX96);

        if (!registry.isEligible(sender)) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint128 tax = BondLib.computeTax(tx.gasprice, block.basefee, cfg);
        if (tax == 0) {
            return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        // Zero specified delta: does not perturb the trader's exact-in/exact-out amount.
        // Positive unspecified delta: hook becomes owed `tax` of the unspecified currency once
        // this swap settles (see ARCHITECTURE_VALIDATION.md #2).
        // Safe: `_validateConfig` enforces config.maxTax <= type(int128).max, and `tax` is
        // clamped to config.maxTax inside `computeTax`.
        // forge-lint: disable-next-line(unsafe-typecast)
        return (this.beforeSwap.selector, toBeforeSwapDelta(0, int128(tax)), 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external onlyPoolManager onlyProtectedPool(key.toId()) returns (bytes4, int128) {
        PoolId poolId = key.toId();
        BackstopConfig memory cfg = config;
        bool eligible = registry.isEligible(sender);
        Currency unspecified = _unspecifiedCurrency(key, params);

        // --- 1. Settle the priority tax charged in beforeSwap (recomputed deterministically;
        //        see ARCHITECTURE_VALIDATION.md #2 for why minting here nets to zero even though
        //        PoolManager credits the hook's matching delta only after this call returns). ---
        if (eligible) {
            uint128 tax = BondLib.computeTax(tx.gasprice, block.basefee, cfg);
            if (tax > 0) {
                poolManager.mint(address(vault), unspecified.toId(), tax);
                emit PriorityTaxCharged(poolId, sender, tax);
            }
        }

        // --- 2. Same-transaction attribution state machine (see MECHANISM.md) ---
        (uint160 sqrtPriceAfterX96,,,) = poolManager.getSlot0(poolId);
        uint160 sqrtPriceBeforeX96 = AttributionLib.loadPreSwapPrice(poolId);
        AttributionLib.Window memory w = AttributionLib.load(poolId);

        if (w.open && sender == w.displacer && params.zeroForOne != w.zeroForOne) {
            // Candidate closing leg.
            PredicateResult memory result = PredicateLib.evaluate(
                w.sqrtPriceOpenX96, w.sqrtPriceAfterOpenX96, sqrtPriceAfterX96, w.victimNotional, w.zeroForOne, params.zeroForOne, cfg
            );
            AttributionLib.close(poolId); // single-shot: always closes, matched or not
            if (result.matched) {
                _settleMatch(poolId, w, result);
            }
        } else if (w.open && sender == w.displacer && params.zeroForOne == w.zeroForOne) {
            // Same displacer extending their own displacement before reversing.
            AttributionLib.openOrExtend(poolId, sender, w.zeroForOne, w.sqrtPriceOpenX96, sqrtPriceAfterX96);
        } else if (w.open && sender != w.displacer && params.zeroForOne == w.zeroForOne) {
            // Same-direction volume from someone else while the window is open — accumulates as
            // victim notional (Case E: multiple victims all accumulate into one aggregate).
            AttributionLib.accumulateVictim(poolId, _notional(params));
        } else if (!w.open && eligible) {
            // Candidate opening leg.
            if (PredicateLib.isDisplacement(sqrtPriceBeforeX96, sqrtPriceAfterX96, cfg.minDisplacementBps)) {
                AttributionLib.openOrExtend(poolId, sender, params.zeroForOne, sqrtPriceBeforeX96, sqrtPriceAfterX96);
            }
        }
        // else: window open, sender is neither the displacer nor moving in its direction — an
        // unrelated third-party trade against the trend. Left untouched (Case F/I).

        return (this.afterSwap.selector, 0);
    }

    // ---------------------------------------------------------------------
    // IHooks — liquidity callbacks (checkpoint only; Backstop takes no cut of liquidity moves)
    // ---------------------------------------------------------------------

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager onlyProtectedPool(key.toId()) returns (bytes4) {
        _checkpoint(key, sender, params.tickLower, params.tickUpper, params.salt);
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) external onlyPoolManager onlyProtectedPool(key.toId()) returns (bytes4) {
        _checkpoint(key, sender, params.tickLower, params.tickUpper, params.salt);
        return this.beforeRemoveLiquidity.selector;
    }

    // ---------------------------------------------------------------------
    // IHooks — unused callbacks. Never invoked (permission bits unset), reachable only if a
    // caller impersonates PoolManager, which onlyPoolManager already blocks.
    // ---------------------------------------------------------------------

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return this.afterInitialize.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        return (this.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external
        pure
        returns (bytes4, BalanceDelta)
    {
        return (this.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.afterDonate.selector;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _checkpoint(PoolKey calldata key, address sender, int24 tickLower, int24 tickUpper, bytes32 salt) internal {
        PoolId poolId = key.toId();
        bytes32 positionKey = Position.calculatePositionKey(sender, tickLower, tickUpper, salt);
        uint128 currentLiquidity = poolManager.getPositionLiquidity(poolId, positionKey);
        vault.checkpoint(poolId, currency0, currency1, sender, tickLower, tickUpper, salt, currentLiquidity);
    }

    /// @dev Converts a slashed bond (already sitting in this contract as raw ERC-20, transferred
    ///      here by `BackstopRegistry.slash`) into a PoolManager ERC-6909 claim credited to the
    ///      vault, then records it in the vault's growth index. See
    ///      ARCHITECTURE_VALIDATION.md #4 for why this sync/transfer/settle/mint sequence is the
    ///      only legal way to move raw tokens into PoolManager's accounting from inside an
    ///      already-unlocked call.
    function _settleMatch(PoolId poolId, AttributionLib.Window memory w, PredicateResult memory result) internal {
        uint256 slashed = registry.slash(w.displacer, config.slashBps);
        emit PatternMatched(poolId, w.displacer, w.victimNotional, result.reversalBps, slashed);
        if (slashed == 0) return;

        poolManager.sync(bondCurrency);
        bool ok = IERC20Minimal(Currency.unwrap(bondCurrency)).transfer(address(poolManager), slashed);
        require(ok, "bond transfer failed");
        poolManager.settle();
        poolManager.mint(address(vault), bondCurrency.toId(), slashed);

        uint128 activeLiquidity = poolManager.getLiquidity(poolId);
        if (activeLiquidity > 0) {
            vault.fund(poolId, bondCurrency, slashed, activeLiquidity);
        }
        // If activeLiquidity == 0, the claim remains held by the vault (already minted above)
        // but unattributed to any position — see MECHANISM.md "Failure modes".
    }

    function _unspecifiedCurrency(PoolKey calldata key, IPoolManager.SwapParams calldata params)
        internal
        pure
        returns (Currency)
    {
        bool exactInput = params.amountSpecified < 0;
        // specified == input  ⟺  exactInput == zeroForOne  (matches Hooks.sol's own convention)
        bool specifiedIsCurrency0 = params.zeroForOne == exactInput;
        return specifiedIsCurrency0 ? key.currency1 : key.currency0;
    }

    function _notional(IPoolManager.SwapParams calldata params) internal pure returns (uint128) {
        int256 amt = params.amountSpecified;
        return uint128(uint256(amt >= 0 ? amt : -amt));
    }
}
