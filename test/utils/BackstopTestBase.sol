// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

import {BackstopHook} from "../../src/BackstopHook.sol";
import {BackstopRegistry} from "../../src/BackstopRegistry.sol";
import {InsuranceVault} from "../../src/InsuranceVault.sol";
import {BackstopConfig} from "../../src/types/BackstopTypes.sol";
import {HookMiner} from "./HookMiner.sol";
import {Bundler} from "./Bundler.sol";

/// @notice Shared test harness: deploys real PoolManager + Backstop contracts against a real
///         pool, and gives tests two distinct swap-router identities (so the hook sees genuinely
///         different `sender` addresses for "searcher" vs "victim" legs — see
///         ARCHITECTURE_VALIDATION.md #1) plus a direct-unlock liquidity path so the test
///         contract itself is the recorded position owner (needed to test LP claiming without
///         periphery's PositionManager indirection).
abstract contract BackstopTestBase is Test, IUnlockCallback {
    using StateLibrary for IPoolManager;

    uint256 internal constant MIN_BOND = 10e18;

    PoolManager internal manager;
    TestERC20 internal token0;
    TestERC20 internal token1;
    PoolKey internal key;
    PoolId internal poolId;

    BackstopRegistry internal registry;
    InsuranceVault internal vault;
    BackstopHook internal hook;
    BackstopConfig internal cfg;

    PoolSwapTest internal routerA; // "searcher" identity
    PoolSwapTest internal routerB; // "victim" / second-actor identity
    Bundler internal bundler; // stands in for a batch router/solver/bundler -- see Bundler.sol

    address internal searcherEOA = makeAddr("searcherEOA");
    address internal victimEOA = makeAddr("victimEOA");

    function setUp() public virtual {
        manager = new PoolManager(address(this));

        TestERC20 a = new TestERC20(0);
        TestERC20 b = new TestERC20(0);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);

        routerA = new PoolSwapTest(manager);
        routerB = new PoolSwapTest(manager);
        bundler = new Bundler();

        registry = new BackstopRegistry(address(token0), MIN_BOND);
        vault = new InsuranceVault(address(manager));

        cfg = defaultConfig();

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            manager,
            registry,
            vault,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            uint24(3000),
            int24(60),
            Currency.wrap(address(token0)),
            address(this),
            cfg
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(address(this), flags, type(BackstopHook).creationCode, constructorArgs);

        hook = new BackstopHook{salt: salt}(
            manager,
            registry,
            vault,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1)),
            3000,
            60,
            Currency.wrap(address(token0)),
            address(this),
            cfg
        );
        require(address(hook) == hookAddr, "hook address mismatch");

        registry.setHook(address(hook));
        vault.setHook(address(hook));

        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 3000, 60, IHooks(address(hook)));
        poolId = key.toId();
        manager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        // Fund the test contract itself (acts as the LP, via direct unlock) generously.
        token0.mint(address(this), 100_000_000e18);
        token1.mint(address(this), 100_000_000e18);

        // Fund the two swap routers' EOA callers.
        token0.mint(searcherEOA, 10_000_000e18);
        token1.mint(searcherEOA, 10_000_000e18);
        token0.mint(victimEOA, 10_000_000e18);
        token1.mint(victimEOA, 10_000_000e18);
        vm.prank(searcherEOA);
        token0.approve(address(routerA), type(uint256).max);
        vm.prank(searcherEOA);
        token1.approve(address(routerA), type(uint256).max);
        vm.prank(victimEOA);
        token0.approve(address(routerB), type(uint256).max);
        vm.prank(victimEOA);
        token1.approve(address(routerB), type(uint256).max);

        // Fund the bundler (the payer identity for every *bundled* multi-leg sequence -- see
        // Bundler.sol for why a single top-level call matters, not just a shared test-function
        // call stack) and pre-approve both routers on its behalf.
        token0.mint(address(bundler), 10_000_000e18);
        token1.mint(address(bundler), 10_000_000e18);
        vm.startPrank(address(bundler));
        token0.approve(address(routerA), type(uint256).max);
        token1.approve(address(routerA), type(uint256).max);
        token0.approve(address(routerB), type(uint256).max);
        token1.approve(address(routerB), type(uint256).max);
        vm.stopPrank();

        // A moderately narrow band, owned directly by this test contract — narrow/shallow enough
        // that swap sizes in the thousands of tokens produce a measurable (>0.3%) price
        // displacement, which the case-bank tests need to actually arm the predicate.
        _addLiquidity(-6_000, 6_000, 5_000e18);
    }

    function defaultConfig() internal pure returns (BackstopConfig memory) {
        return BackstopConfig({
            priorityTaxBps: 1000, // 10% of the gas premium
            minFlatTax: 1e14,
            maxTax: 1e24,
            minDisplacementBps: 30, // 0.3%
            minVictimNotional: 1e18,
            minReversalBps: 5000, // 50%
            slashBps: 2000 // 20% of bond
        });
    }

    // ---------------------------------------------------------------------
    // Direct-unlock liquidity helper: the test contract is the recorded owner.
    // ---------------------------------------------------------------------

    struct LiqCallback {
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
    }

    function _addLiquidity(int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal {
        manager.unlock(abi.encode(LiqCallback(tickLower, tickUpper, liquidityDelta)));
    }

    function unlockCallback(bytes calldata rawData) external returns (bytes memory) {
        require(msg.sender == address(manager));
        LiqCallback memory d = abi.decode(rawData, (LiqCallback));

        (BalanceDelta delta,) = manager.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: d.tickLower,
                tickUpper: d.tickUpper,
                liquidityDelta: d.liquidityDelta,
                salt: bytes32(0)
            }),
            ""
        );
        _settleDelta(key.currency0, delta.amount0());
        _settleDelta(key.currency1, delta.amount1());
        return "";
    }

    function _settleDelta(Currency currency, int128 amount) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    // ---------------------------------------------------------------------
    // Swap / bond helpers shared by the integration test suite
    // ---------------------------------------------------------------------

    /// @dev Exact-input swap of `amountIn` via `router`, called as `eoa`. Returns the resulting
    ///      BalanceDelta. `router`'s own address is what BackstopHook sees as `sender`.
    function _swap(PoolSwapTest router, address eoa, bool zeroForOne, uint256 amountIn)
        internal
        returns (BalanceDelta)
    {
        vm.prank(eoa);
        return router.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    struct Leg {
        PoolSwapTest router;
        bool zeroForOne;
        uint256 amountIn;
    }

    /// @dev Builds the calldata for one leg of a bundle (see `_bundle`).
    function _swapCall(bool zeroForOne, uint256 amountIn) internal view returns (bytes memory) {
        return abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                IPoolManager.SwapParams({
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                bytes("")
            )
        );
    }

    /// @notice Executes every leg of `legs` as ONE top-level call into `bundler`, so they are
    ///         genuinely nested calls within a single transaction/EVM context — the only
    ///         methodology that is valid under both Foundry's default test execution and
    ///         `--isolate`/`--gas-report` mode (which executes separate top-level calls as
    ///         separate transactions, correctly clearing EIP-1153 transient storage between
    ///         them). See Bundler.sol for the full rationale; every multi-leg predicate test in
    ///         this suite MUST go through this helper, never call `_swap` directly per leg.
    function _bundle(Leg[] memory legs) internal {
        address[] memory targets = new address[](legs.length);
        bytes[] memory data = new bytes[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            targets[i] = address(legs[i].router);
            data[i] = _swapCall(legs[i].zeroForOne, legs[i].amountIn);
        }
        bundler.execute(targets, data);
    }

    /// @dev Bonds `router`'s own address (the identity BackstopHook actually sees) with
    ///      `amount` of the bond asset (token0), funding and approving on its behalf via prank —
    ///      standard Foundry technique for giving a logic-less router contract token approvals.
    function _bondRouter(PoolSwapTest router, uint256 amount) internal {
        token0.mint(address(router), amount);
        vm.prank(address(router));
        token0.approve(address(registry), amount);
        vm.prank(address(router));
        registry.deposit(amount);
    }
}
