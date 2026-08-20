// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice A minimal multicall bundler standing in for a real batch router / intent-solver /
///         ERC-4337 bundler — the class of contract that genuinely produces the "same-
///         transaction, multiple swap() calls from different senders" pattern Backstop is
///         designed to observe (see ARCHITECTURE_VALIDATION.md #5).
///
/// @dev This is not cosmetic. Foundry's *default* `forge test` execution runs an entire test
///      function's body — including every top-level call it makes to other contracts — inside
///      one shared EVM context, which happens to let EIP-1153 transient storage bleed across
///      calls that are NOT actually nested from a single caller. That default behavior does not
///      match real chain semantics: on a real chain (and under Foundry's own `--isolate` /
///      `--gas-report` mode, which correctly executes each top-level call as its own separate
///      transaction/EVM context), separate top-level calls get separate, freshly-cleared
///      transient storage, exactly per EIP-1153. A test suite that calls `routerA.swap(...)`,
///      `routerB.swap(...)`, `routerA.swap(...)` directly as three separate top-level calls is
///      therefore only "passing" by accident of Foundry's non-isolated default — it is not
///      proof the pattern is detected within one real transaction. Routing every multi-leg
///      sequence through this bundler's single `execute` call makes the three legs genuinely
///      nested calls within one EVM context, which is correct under both modes and is what this
///      repo's tests are verified against (`forge test --isolate`), not just the default.
contract Bundler {
    function execute(address[] calldata targets, bytes[] calldata data) external returns (bytes[] memory results) {
        require(targets.length == data.length, "length mismatch");
        results = new bytes[](targets.length);
        for (uint256 i; i < targets.length; i++) {
            (bool ok, bytes memory ret) = targets[i].call(data[i]);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
            results[i] = ret;
        }
    }
}
