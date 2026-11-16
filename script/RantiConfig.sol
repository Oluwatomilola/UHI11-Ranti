// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RantiHook} from "../src/RantiHook.sol";
import {StrategyRegistry} from "../src/StrategyRegistry.sol";

/// @notice Demo-speed parameters for a live testnet run: 10-minute epochs so the whole
/// lifecycle (shadow -> graduation -> live -> fees -> migration) fits in a couple of hours.
library RantiConfig {
    function hook() internal pure returns (RantiHook.Config memory c) {
        c.epochLength = 10 minutes;
        c.twapWindow = 5 minutes;
        c.oracleInterval = 10;
        c.vestingPeriod = 10 minutes;
        c.maxTickDeviation = 200;
        c.perfFeeBps = 2_000;
        c.bondSlashBps = 5_000;
        c.minBondValue = 1e18;
    }

    function registry() internal pure returns (StrategyRegistry.Params memory p) {
        p.minShadowEpochs = 3;
        p.challengeWindow = 3;
        p.tenureEpochs = 4;
        p.capGrowthBps = 2_500;
        p.capHaircutBps = 3_000;
        p.capMultiple = 2;
        p.maxDrawdownWad = 0.05e18;
        p.targetExcessWad = 0.0005e18;
        p.zScoreWad = 1e18;
        p.capFloor = 1e18;
        p.probationCapCeiling = 1_000e18;
        p.tenuredCapCeiling = 100_000e18;
    }
}
