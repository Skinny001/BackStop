// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IBackstopRegistry {
    event BondDeposited(address indexed searcher, uint256 amount, uint256 newBond);
    event BondWithdrawn(address indexed searcher, uint256 amount, uint256 newBond);
    event BondSlashed(address indexed searcher, uint256 amount, uint256 newBond);

    error BelowMinBond();
    error InsufficientBond();
    error NotHook();
    error ZeroAmount();
    error NotDeployer();
    error HookAlreadySet();

    /// @notice Deposits `amount` of the bond asset, crediting `msg.sender`'s bond.
    function deposit(uint256 amount) external;

    /// @notice Withdraws `amount` of the caller's bond, reverting if it would go negative.
    function withdraw(uint256 amount) external;

    /// @notice Slashes up to `slashBps` of `searcher`'s current bond. Callable only by the hook.
    /// @return slashed The actual amount removed (capped at the current bond).
    function slash(address searcher, uint16 slashBps) external returns (uint256 slashed);

    /// @notice True if `searcher` currently holds at least `minBond`.
    function isEligible(address searcher) external view returns (bool);

    function bond(address searcher) external view returns (uint256);
}
