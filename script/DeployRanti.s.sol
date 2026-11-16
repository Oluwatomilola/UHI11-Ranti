// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {RantiHook} from "../src/RantiHook.sol";
import {CenteredRangeStrategy} from "../src/strategies/CenteredRangeStrategy.sol";
import {RantiConfig} from "./RantiConfig.sol";

/// @notice Deploys Ranti on Unichain Sepolia (or any chain with a v4 PoolManager).
///
///   forge script script/DeployRanti.s.sol --rpc-url unichain_sepolia --broadcast --private-key $PK
///
/// Env (optional):
///   POOL_MANAGER   v4 PoolManager (default: Unichain Sepolia 0x00b036b58a818b1bc34d502d3fe730db729e62ac)
///   TOKEN_A/TOKEN_B existing ERC-20s; if unset, two mock tokens are deployed and minted to you
///   BOND           bond per side for each demo strategy (default 100e18)
contract DeployRanti is Script {
    address internal constant UNICHAIN_SEPOLIA_POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        IPoolManager manager = IPoolManager(vm.envOr("POOL_MANAGER", UNICHAIN_SEPOLIA_POOL_MANAGER));
        uint256 bond = vm.envOr("BOND", uint256(100e18));

        vm.startBroadcast();
        address me = msg.sender;

        // 1. Tokens
        address ta = vm.envOr("TOKEN_A", address(0));
        address tb = vm.envOr("TOKEN_B", address(0));
        if (ta == address(0) || tb == address(0)) {
            MockERC20 a = new MockERC20("Ranti Test A", "RTA", 18);
            MockERC20 b = new MockERC20("Ranti Test B", "RTB", 18);
            a.mint(me, 1_000_000e18);
            b.mint(me, 1_000_000e18);
            ta = address(a);
            tb = address(b);
        }
        (address t0, address t1) = ta < tb ? (ta, tb) : (tb, ta);

        // 2. Hook at an address whose low bits encode its permissions
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG
        );
        bytes memory args = abi.encode(manager, RantiConfig.hook(), RantiConfig.registry(), "Ranti Vault Share", "rVLT");
        (address predicted, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(RantiHook).creationCode, args);
        RantiHook hook = new RantiHook{salt: salt}(
            manager, RantiConfig.hook(), RantiConfig.registry(), "Ranti Vault Share", "rVLT"
        );
        require(address(hook) == predicted, "hook address mismatch");

        // 3. Pool: the hook binds to the first pool initialised with it
        PoolKey memory key = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, SQRT_PRICE_1_1);

        // 4. Demo strategies
        CenteredRangeStrategy narrow = new CenteredRangeStrategy("Narrow +-1.2%", 120);
        CenteredRangeStrategy medium = new CenteredRangeStrategy("Medium +-6%", 600);
        CenteredRangeStrategy wide = new CenteredRangeStrategy("Wide +-27%", 2400);

        // 5. Register two shadows with the deployer's bond (they start earning a track record)
        MockERC20(t0).approve(address(hook), type(uint256).max);
        MockERC20(t1).approve(address(hook), type(uint256).max);
        uint256 nId = hook.registerStrategy(narrow, bond, bond);
        uint256 wId = hook.registerStrategy(wide, bond, bond);

        vm.stopBroadcast();

        console2.log("PoolManager      ", address(manager));
        console2.log("Token0           ", t0);
        console2.log("Token1           ", t1);
        console2.log("RantiHook        ", address(hook));
        console2.log("StrategyRegistry ", address(hook.registry()));
        console2.log("CuratorEscrow    ", address(hook.escrow()));
        console2.log("Narrow strategy  ", address(narrow), "id", nId);
        console2.log("Wide strategy    ", address(wide), "id", wId);
        console2.log("Medium strategy  ", address(medium), "(not registered)");
    }
}
