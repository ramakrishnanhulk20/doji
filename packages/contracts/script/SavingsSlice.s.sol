// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {DeployCore} from "./DeployCore.s.sol";
import {CreditMarkets} from "../src/CreditMarkets.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {PassThrough} from "../src/libraries/PassThrough.sol";

/// @title SavingsSlice
/// @notice Deploys a slice pair, a CreditMarkets and a LoanManager wired to each other and to Mezo's real testnet
///         sMUSD vault, with exactly DeployCore's testnet settings and preflight, and records it in
///         deployments/31611-slice-savings.json. script/savings-slice.sh runs this, then proves a parked offer on
///         the pair with live transactions. The 20 Oct deployment and its records are never read or written here.
/// @dev forge script script/SavingsSlice.s.sol --rpc-url "$MEZO_TESTNET_RPC" --broadcast --skip-simulation --slow
///      Without --libraries forge deploys the PassThrough library itself through the standard CREATE2 deployer,
///      and DeployCore's preflight refuses it unless its runtime code matches the compiled artifact. Reads
///      DEPLOYER_PRIVATE_KEY and DEPLOYER_ADDRESS from .env, and SAVINGS_VAULT if set. Only a broadcast writes the
///      record, so a dry run can never leave addresses that hold no code.
contract SavingsSlice is DeployCore {
    error VaultNotWired(address expected, address wired);

    function run() public override {
        (uint256 key, address deployer) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        ChainConfig memory cfg = _config();
        (CreditMarkets cm, LoanManager lm) = _deployCore(cfg, key, deployer);
        if (cm.savingsVault() != cfg.savingsVault) revert VaultNotWired(cfg.savingsVault, cm.savingsVault());
        console.log("sMUSD vault  ", cfg.savingsVault);
        _recordSlice(cfg, cm, lm, deployer);
    }

    function _recordSlice(ChainConfig memory cfg, CreditMarkets cm, LoanManager lm, address deployer) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log("dry run: no record written");
            return;
        }
        string memory obj = "slice";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeBool(obj, "broadcast", true);
        vm.serializeUint(obj, "block", block.number);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "veBTC", cfg.veBTC);
        vm.serializeAddress(obj, "musd", cfg.musd);
        vm.serializeAddress(obj, "btc", cfg.btc);
        vm.serializeAddress(obj, "priceFeed", cfg.priceFeed);
        vm.serializeAddress(obj, "poolsVoter", cfg.poolsVoter);
        vm.serializeAddress(obj, "validatorsVoter", cfg.validatorsVoter);
        vm.serializeAddress(obj, "feeDistributor", cfg.feeDistributor);
        vm.serializeUint(obj, "lockLayoutWords", cfg.lockLayoutWords);
        vm.serializeAddress(obj, "savingsVault", cfg.savingsVault);
        vm.serializeAddress(obj, "creditMarkets", address(cm));
        vm.serializeAddress(obj, "passThrough", address(PassThrough));
        vm.serializeBytes32(obj, "passThroughCodeHash", _passThroughCodeHash());
        string memory json = vm.serializeAddress(obj, "loanManager", address(lm));

        string memory dir = _deploymentsDir();
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", vm.toString(block.chainid), "-slice-savings.json");
        vm.writeJson(json, path);
        console.log("wrote", path);
    }
}
