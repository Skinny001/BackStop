// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

import {BackstopHook} from "../src/BackstopHook.sol";
import {BackstopRegistry} from "../src/BackstopRegistry.sol";
import {InsuranceVault} from "../src/InsuranceVault.sol";
import {DemoRouter} from "./DemoRouter.sol";
import {Bundler} from "../test/utils/Bundler.sol";

/// @notice Deterministic, reproducible on-chain demo of the Backstop "wow moment": bond, tax,
///         same-transaction sandwich pattern, slash, insurance funding, LP payout — all
///         constructed explicitly by this script rather than waited for from real MEV activity
///         (per the brief's "Demo Safety" requirement: no mempool dependency, no bots).
///
///         The three swap legs (open / victim / close) are executed via ONE call to `Bundler`,
///         not three separate broadcast transactions. This is not a style choice: `forge script`
///         broadcasts each top-level call it makes as its own independent, separately-mined
///         transaction, and EIP-1153 transient storage is correctly cleared between separate
///         transactions (verified directly against a real Anvil chain during development — see
///         ARCHITECTURE_VALIDATION.md / SECURITY.md "same-transaction" finding). Only calls
///         nested inside one top-level transaction share attribution state. Routing the three
///         legs through `Bundler.execute` in a single broadcast call reproduces the actual
///         same-transaction pattern this hook is built to observe.
///
///         Run after Deploy.s.sol. Required env vars: PRIVATE_KEY, POOL_MANAGER, BACKSTOP_HOOK,
///         BACKSTOP_REGISTRY, INSURANCE_VAULT, CURRENCY0, CURRENCY1, POOL_FEE, TICK_SPACING.
///
///         Usage:
///           forge script script/Demo.s.sol:Demo --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
///             --private-key $PRIVATE_KEY --broadcast -vvvv
contract Demo is Script {
    using StateLibrary for IPoolManager;

    uint256 constant BOND = 1_000e18;
    uint256 constant OPEN_AMOUNT = 40e18;
    uint256 constant VICTIM_AMOUNT = 10e18;
    uint256 constant LP_LIQUIDITY = 5_000e18;
    uint256 constant BUNDLER_FUNDING = 10_000e18;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");

        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        BackstopHook hook = BackstopHook(vm.envAddress("BACKSTOP_HOOK"));
        BackstopRegistry registry = BackstopRegistry(vm.envAddress("BACKSTOP_REGISTRY"));
        InsuranceVault vault = InsuranceVault(vm.envAddress("INSURANCE_VAULT"));
        IERC20Minimal currency0 = IERC20Minimal(vm.envAddress("CURRENCY0"));
        IERC20Minimal currency1 = IERC20Minimal(vm.envAddress("CURRENCY1"));
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));

        PoolKey memory key = PoolKey(
            Currency.wrap(address(currency0)), Currency.wrap(address(currency1)), fee, tickSpacing, IHooks(address(hook))
        );
        PoolId poolId = key.toId();

        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        console2.log("=== Step 1: deploying bundler + demo actor routers (LP / searcher / victim) ===");
        Bundler bundler = new Bundler();
        DemoRouter lp = new DemoRouter(poolManager, registry, vault, me, address(0));
        DemoRouter searcher = new DemoRouter(poolManager, registry, vault, me, address(bundler));
        DemoRouter victim = new DemoRouter(poolManager, registry, vault, me, address(bundler));
        console2.log("bundler:        ", address(bundler));
        console2.log("lp router:      ", address(lp));
        console2.log("searcher router:", address(searcher));
        console2.log("victim router:  ", address(victim));

        console2.log("=== Step 2: LP adds liquidity ===");
        currency0.approve(address(lp), type(uint256).max);
        currency1.approve(address(lp), type(uint256).max);
        lp.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -6_000,
                tickUpper: 6_000,
                liquidityDelta: int256(LP_LIQUIDITY),
                salt: 0
            })
        );

        console2.log("=== Step 3: insurance reserve starts at ===");
        console2.log(poolManager.balanceOf(address(vault), key.currency0.toId()));

        console2.log("=== Step 4: searcher deposits bond (does not need to be same-tx as the swaps) ===");
        currency0.approve(address(searcher), BOND);
        searcher.bond(currency0, BOND);
        console2.log("searcher bond:    ", registry.bond(address(searcher)));
        console2.log("searcher eligible:", registry.isEligible(address(searcher)));

        console2.log("=== Step 5: fund the bundler and approve it through to both routers ===");
        currency0.transfer(address(bundler), BUNDLER_FUNDING);
        currency1.transfer(address(bundler), BUNDLER_FUNDING);
        {
            address[] memory targets = new address[](4);
            bytes[] memory data = new bytes[](4);
            targets[0] = address(currency0);
            data[0] = abi.encodeCall(IERC20Minimal.approve, (address(searcher), type(uint256).max));
            targets[1] = address(currency1);
            data[1] = abi.encodeCall(IERC20Minimal.approve, (address(searcher), type(uint256).max));
            targets[2] = address(currency0);
            data[2] = abi.encodeCall(IERC20Minimal.approve, (address(victim), type(uint256).max));
            targets[3] = address(currency1);
            data[3] = abi.encodeCall(IERC20Minimal.approve, (address(victim), type(uint256).max));
            bundler.execute(targets, data);
        }

        console2.log("=== Step 6: ONE transaction -- open / victim / close, nested via Bundler ===");
        {
            address[] memory targets = new address[](3);
            bytes[] memory data = new bytes[](3);
            targets[0] = address(searcher);
            data[0] = abi.encodeCall(
                DemoRouter.swap,
                (
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: false,
                        amountSpecified: -int256(OPEN_AMOUNT),
                        sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                    })
                )
            );
            targets[1] = address(victim);
            data[1] = abi.encodeCall(
                DemoRouter.swap,
                (
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: false,
                        amountSpecified: -int256(VICTIM_AMOUNT),
                        sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
                    })
                )
            );
            targets[2] = address(searcher);
            data[2] = abi.encodeCall(
                DemoRouter.swap,
                (
                    key,
                    IPoolManager.SwapParams({
                        zeroForOne: true,
                        amountSpecified: -int256(OPEN_AMOUNT),
                        sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                    })
                )
            );
            bundler.execute(targets, data);
        }

        console2.log("=== Step 7: bond slashed ===");
        console2.log("searcher bond after:", registry.bond(address(searcher)));

        console2.log("=== Step 8: insurance reserve after ===");
        console2.log(poolManager.balanceOf(address(vault), key.currency0.toId()));

        console2.log("=== Step 9: LP claims automatic entitlement ===");
        (uint256 amount0, uint256 amount1) =
            lp.claim(poolId, key.currency0, key.currency1, -6_000, 6_000, bytes32(0));
        console2.log("LP received (currency0):", amount0);
        console2.log("LP received (currency1):", amount1);

        console2.log("=== Step 10: done -- the attacker funded the insurance that paid the LP ===");

        vm.stopBroadcast();
    }
}
