// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBackstopRegistry} from "./interfaces/IBackstopRegistry.sol";
import {BondLib} from "./libraries/BondLib.sol";
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

/// @title BackstopRegistry
/// @notice Bond custody for searchers seeking priority-lane access to a Backstop-protected pool.
///         Pool-agnostic: one registry can back multiple hooks sharing the same bond asset.
/// @dev Slashing is the only privileged state-changing entrypoint; it is restricted to the
///      single `hook` address, which is set exactly once after construction (see `setHook`).
///      `hook` cannot be a constructor argument because BackstopHook's own constructor requires
///      this registry's address (and the vault's) to already exist — a genuine circular
///      dependency between the three contracts, resolved with a one-time post-deploy wiring step
///      restricted to the original deployer rather than a CREATE2 address-prediction dance.
///      See MECHANISM.md "Bond lifecycle".
contract BackstopRegistry is IBackstopRegistry {
    IERC20Minimal public immutable bondAsset;
    uint256 public immutable minBond;
    address private immutable deployer;

    address public hook;

    mapping(address => uint256) public bond;

    modifier onlyHook() {
        if (msg.sender != hook) revert NotHook();
        _;
    }

    constructor(address bondAsset_, uint256 minBond_) {
        bondAsset = IERC20Minimal(bondAsset_);
        minBond = minBond_;
        deployer = msg.sender;
    }

    /// @notice One-time wiring of the authorized hook address. Callable only by whoever deployed
    ///         this registry, and only once — after which `hook` behaves as if it were immutable.
    function setHook(address hook_) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (hook != address(0)) revert HookAlreadySet();
        hook = hook_;
    }

    /// @inheritdoc IBackstopRegistry
    function deposit(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        // checks-effects-interactions: state updated before the external transferFrom call
        uint256 newBond = bond[msg.sender] + amount;
        bond[msg.sender] = newBond;
        bool ok = bondAsset.transferFrom(msg.sender, address(this), amount);
        if (!ok) revert ZeroAmount(); // transferFrom returning false; SafeERC20 avoided to keep the dependency surface minimal, ok=false is treated as failure
        emit BondDeposited(msg.sender, amount, newBond);
    }

    /// @inheritdoc IBackstopRegistry
    function withdraw(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 current = bond[msg.sender];
        if (amount > current) revert InsufficientBond();
        uint256 newBond = current - amount;
        bond[msg.sender] = newBond;
        bool ok = bondAsset.transfer(msg.sender, amount);
        if (!ok) revert InsufficientBond();
        emit BondWithdrawn(msg.sender, amount, newBond);
    }

    /// @inheritdoc IBackstopRegistry
    function slash(address searcher, uint16 slashBps) external onlyHook returns (uint256 slashed) {
        uint256 current = bond[searcher];
        slashed = BondLib.computeSlash(current, slashBps);
        if (slashed == 0) return 0;
        uint256 newBond = current - slashed; // safe: computeSlash caps at `current`
        bond[searcher] = newBond;
        // Slashed principal is transferred to the hook, which forwards it into the insurance
        // vault as part of the same atomic settlement (see BackstopHook `_settle`).
        bool ok = bondAsset.transfer(hook, slashed);
        if (!ok) revert InsufficientBond();
        emit BondSlashed(searcher, slashed, newBond);
    }

    /// @inheritdoc IBackstopRegistry
    function isEligible(address searcher) external view returns (bool) {
        return bond[searcher] >= minBond;
    }
}
