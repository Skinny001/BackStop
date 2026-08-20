// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {BackstopHook} from "../src/BackstopHook.sol";
import {BackstopRegistry} from "../src/BackstopRegistry.sol";
import {InsuranceVault} from "../src/InsuranceVault.sol";
import {BackstopConfig} from "../src/types/BackstopTypes.sol";
import {HookMiner} from "../test/utils/HookMiner.sol";

/// @notice Deploys Backstop against Unichain Sepolia (or any chain given via --rpc-url).
///
/// Required env vars:
///   PRIVATE_KEY         - deployer key (funds gas + initial liquidity)
///   CURRENCY0, CURRENCY1 - the protected pool's two token addresses, currency0 < currency1
///
/// Optional env vars (sensible defaults applied otherwise):
///   POOL_MANAGER        - an already-deployed PoolManager to use. If unset, a fresh one is
///                          deployed (fine for a from-scratch demo pool; for a canonical/shared
///                          Unichain Sepolia PoolManager, pass its real address here instead of
///                          letting this script deploy a private one).
///   POOL_FEE             - default 3000 (0.3%)
///   TICK_SPACING          - default 60
///   MIN_BOND              - default 10e18
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $UNICHAIN_SEPOLIA_RPC_URL \
///     --private-key $PRIVATE_KEY \
///     --broadcast --verify -vvvv
///
/// This script is provided as a complete, runnable deliverable. It was NOT executed against a
/// live network as part of this engineering pass — broadcasting consumes real testnet funds and
/// creates irreversible on-chain state, which is a deliberate action for the project owner to
/// take with their own funded key, not something to run silently. Dry-run first with `forge
/// script` (no --broadcast) to confirm the plan.
contract Deploy is Script {
    // CREATE2 deployer proxy Foundry/forge script uses for salt-mined deployments.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        address currency0Addr = vm.envAddress("CURRENCY0");
        address currency1Addr = vm.envAddress("CURRENCY1");
        require(currency0Addr < currency1Addr, "CURRENCY0 must be < CURRENCY1");

        address poolManagerAddr = vm.envOr("POOL_MANAGER", address(0));
        uint24 fee = uint24(vm.envOr("POOL_FEE", uint256(3000)));
        int24 tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        uint256 minBond = vm.envOr("MIN_BOND", uint256(10e18));

        vm.startBroadcast(deployerKey);

        IPoolManager poolManager;
        if (poolManagerAddr == address(0)) {
            poolManager = IPoolManager(address(new PoolManager(deployer)));
            console2.log("Deployed fresh PoolManager:", address(poolManager));
        } else {
            poolManager = IPoolManager(poolManagerAddr);
            console2.log("Using existing PoolManager:", address(poolManager));
        }

        BackstopRegistry registry = new BackstopRegistry(currency0Addr, minBond);
        InsuranceVault vault = new InsuranceVault(address(poolManager));
        console2.log("BackstopRegistry:", address(registry));
        console2.log("InsuranceVault:  ", address(vault));

        BackstopConfig memory cfg = BackstopConfig({
            priorityTaxBps: 1000,
            minFlatTax: 1e14,
            maxTax: 1e22,
            minDisplacementBps: 30,
            minVictimNotional: 1e18,
            minReversalBps: 5000,
            slashBps: 2000
        });

        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            poolManager,
            registry,
            vault,
            Currency.wrap(currency0Addr),
            Currency.wrap(currency1Addr),
            fee,
            tickSpacing,
            Currency.wrap(currency0Addr), // bond asset = currency0
            deployer,
            cfg
        );
        (address hookAddr, bytes32 salt) =
            HookMiner.find(CREATE2_DEPLOYER, flags, type(BackstopHook).creationCode, constructorArgs);

        BackstopHook hook = new BackstopHook{salt: salt}(
            poolManager,
            registry,
            vault,
            Currency.wrap(currency0Addr),
            Currency.wrap(currency1Addr),
            fee,
            tickSpacing,
            Currency.wrap(currency0Addr),
            deployer,
            cfg
        );
        require(address(hook) == hookAddr, "hook address mismatch");
        console2.log("BackstopHook:    ", address(hook));

        registry.setHook(address(hook));
        vault.setHook(address(hook));

        PoolKey memory key =
            PoolKey(Currency.wrap(currency0Addr), Currency.wrap(currency1Addr), fee, tickSpacing, IHooks(address(hook)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        console2.log("Pool initialized at tick 0");

        vm.stopBroadcast();

        console2.log("--- Deployment complete ---");
        console2.log("PoolManager    ", address(poolManager));
        console2.log("BackstopRegistry", address(registry));
        console2.log("InsuranceVault  ", address(vault));
        console2.log("BackstopHook    ", address(hook));
        console2.log("currency0 (bond asset)", currency0Addr);
        console2.log("currency1", currency1Addr);
    }
}
