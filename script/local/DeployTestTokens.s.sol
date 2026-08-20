// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {TestERC20} from "v4-core/test/TestERC20.sol";

/// @dev Local-anvil-only helper to stand up two ordered demo tokens with an initial mint to the
///      deployer, so Deploy.s.sol / Demo.s.sol can be exercised end-to-end without a live testnet.
///      Not part of the production deployment flow.
contract DeployTestTokens is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(pk);
        TestERC20 a = new TestERC20(1_000_000_000e18);
        TestERC20 b = new TestERC20(1_000_000_000e18);
        vm.stopBroadcast();
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        console2.log("CURRENCY0=%s", c0);
        console2.log("CURRENCY1=%s", c1);
    }
}
