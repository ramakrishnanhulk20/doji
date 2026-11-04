// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";

/// @title ForkNode
/// @notice Picks the node a fork test runs against. MEZO_MAINNET_RPC or MEZO_TESTNET_RPC, when set, replaces the
///         foundry.toml alias, so a stranger whose default public node is down can switch with one environment
///         variable. Unset or empty, the alias is used exactly as before.
/// @dev forge loads packages/contracts/.env by itself, so a value there counts as set; a value in the shell wins
///      over .env. The chain id is checked after the switch, so a mainnet variable pointed at testnet, or the
///      reverse, fails at once instead of running a suite against the wrong chain. Only the host is logged,
///      because a paid node can carry its key in the URL's path, query or user part.
library ForkNode {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 internal constant TESTNET_CHAIN_ID = 31_611;
    uint256 internal constant MAINNET_CHAIN_ID = 31_612;

    error WrongChain(string variable, uint256 expected, uint256 actual);

    function selectMainnet() internal returns (uint256 forkId) {
        return _select("MEZO_MAINNET_RPC", "mezo_mainnet", MAINNET_CHAIN_ID);
    }

    function selectTestnet() internal returns (uint256 forkId) {
        return _select("MEZO_TESTNET_RPC", "mezo_testnet", TESTNET_CHAIN_ID);
    }

    /// @dev forge returns an empty string for a variable set to nothing, so empty falls back to the alias too.
    function _select(string memory variable, string memory rpcAlias, uint256 chainId) private returns (uint256 forkId) {
        string memory url = VM.envOr(variable, string(""));
        bool fromVariable = bytes(url).length != 0;
        forkId = VM.createSelectFork(fromVariable ? url : rpcAlias);
        if (block.chainid != chainId) revert WrongChain(variable, chainId, block.chainid);
        if (fromVariable) {
            console.log("fork node from", variable, _host(url));
        } else {
            console.log("fork node from the foundry.toml alias", rpcAlias);
        }
    }

    /// @dev scheme://[user@]host[:port][/path][?query]: keeps only host and port.
    function _host(string memory url) private pure returns (string memory) {
        string[] memory parts = VM.split(url, "/");
        if (parts.length < 3 || bytes(parts[1]).length != 0) return "(not a scheme://host URL)";
        string[] memory afterUser = VM.split(parts[2], "@");
        return VM.split(afterUser[afterUser.length - 1], "?")[0];
    }
}
