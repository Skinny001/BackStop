// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BackstopConfig} from "../types/BackstopTypes.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

interface IBackstopHook {
    event ConfigUpdated(BackstopConfig config);
    event PriorityTaxCharged(PoolId indexed poolId, address indexed searcher, uint256 amount);
    event PatternMatched(
        PoolId indexed poolId, address indexed displacer, uint256 victimNotional, uint256 reversalBps, uint256 slashed
    );

    error NotPoolManager();
    error NotOwner();
    error BondAssetNotInPool();
    error WrongPool();
}
