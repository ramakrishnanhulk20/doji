// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Faucet} from "../src/Faucet.sol";

/// @title DeployFaucet
/// @notice Deploys the starter-kit Faucet to Mezo testnet in one transaction, with the deployer as owner, and records
///         it in deployments/<DEPLOYMENT_NAME>.json (the name defaults to 31611-faucet). A dry run writes no record.
///         A broadcast refuses to start if its record already exists, so no earlier deployment is ever overwritten.
/// @dev Dry run, from packages/contracts: forge script script/DeployFaucet.s.sol --rpc-url mezo_testnet
///      Deploy: forge script script/DeployFaucet.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow
///      Reads DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS, RELAYER_PRIVATE_KEY, RELAYER_ADDRESS and KEEPER_ADDRESS from
///      .env, and if set DEPLOYMENT_NAME and the BORROWER, BORROWER2 and BUYER wallets. Kit and limit are constants
///      here so verification and the live proof read the same numbers. Mainnet is refused on purpose.
///      The read-back runs in forge's local run, before anything is sent, so a failure there sends nothing. It
///      cannot show what landed: script/faucet-live.sh repeats it against the live chain.
contract DeployFaucet is Script {
    uint256 internal constant TESTNET_CHAIN_ID = 31_611;
    address internal constant MUSD = 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503;
    uint128 internal constant BTC_PER_CLAIM = 0.001e18;
    uint128 internal constant MUSD_PER_CLAIM = 25e18;
    uint32 internal constant DAILY_LIMIT = 40;
    uint256 internal constant MAX_NAME_BYTES = 64;

    error UnsupportedChain(uint256 chainId);
    error KeyAddressMismatch(address fromKey, address configured);
    error MissingCode(address target);
    error RefusingToOverwriteRecord(string path);
    error BadDeploymentName(string name);
    error RelayerIsKnownWallet(address relayer);
    error WiringMismatch(string what, address expected, address actual);
    error SettingMismatch(string what, uint256 expected, uint256 actual);
    error SettingAboveCap(string setting, uint256 value, uint256 cap);

    function run() public {
        string memory path = _recordPath();
        if (block.chainid != TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
        (uint256 key, address deployer) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        (, address relayer) = _wallet("RELAYER_PRIVATE_KEY", "RELAYER_ADDRESS");
        checkRelayer(relayer, deployer, _knownWallets());
        if (MUSD.code.length == 0) revert MissingCode(MUSD);
        console.log("preflight: relayer differs from the owner and every known wallet", relayer);

        vm.startBroadcast(key);
        Faucet faucet = new Faucet(MUSD, deployer, relayer, BTC_PER_CLAIM, MUSD_PER_CLAIM, DAILY_LIMIT);
        vm.stopBroadcast();
        console.log("Faucet", address(faucet));

        checkDeployed(faucet, deployer, relayer);
        console.log("read-back: code, MUSD, roles, kit and limit match, all under the faucet's caps");
        _record(path, faucet, deployer, relayer);
    }

    /// @notice C65: refuses a relayer that is the owner or any listed wallet, so a stolen relayer key reaches
    ///         nothing but the relayer's own job.
    /// @dev Covers the owner and the list it is given, which _knownWallets builds from the wallet names .env.example
    ///      documents. It cannot see a wallet under a new name; script/faucet-live.sh sweeps every *_ADDRESS and
    ///      *_PRIVATE_KEY in .env itself. Reverts RelayerIsKnownWallet.
    /// @param relayer The relayer to check.
    /// @param owner The faucet's owner.
    /// @param wallets Every other wallet to refuse. Zero entries, meaning a wallet not configured, are skipped.
    function checkRelayer(address relayer, address owner, address[] memory wallets) public pure {
        if (relayer == owner) revert RelayerIsKnownWallet(relayer);
        uint256 count = wallets.length;
        for (uint256 i; i < count; ++i) {
            if (wallets[i] != address(0) && wallets[i] == relayer) revert RelayerIsKnownWallet(relayer);
        }
    }

    /// @notice C82: reads a deployed faucet back from itself and refuses anything but what this script asked for:
    ///         code at the address, the fixed MUSD, the roles, no ownership transfer started, not paused, and a kit
    ///         and limit equal to the settings here and under the contract's own caps.
    /// @dev The faucet holds no BTC ERC-20 address: it reads native BTC only, so there is no BTC address to compare.
    ///      Reverts MissingCode, WiringMismatch, SettingMismatch or SettingAboveCap.
    /// @param faucet The faucet to check.
    /// @param owner The expected owner.
    /// @param relayer The expected relayer.
    function checkDeployed(Faucet faucet, address owner, address relayer) public view {
        if (address(faucet).code.length == 0) revert MissingCode(address(faucet));
        _expect("Faucet.musd", MUSD, address(faucet.musd()));
        _expect("Faucet.owner", owner, faucet.owner());
        _expect("Faucet.pendingOwner", address(0), faucet.pendingOwner());
        _expect("Faucet.relayer", relayer, faucet.relayer());
        _expectSetting("Faucet.btcPerClaim", BTC_PER_CLAIM, faucet.btcPerClaim());
        _expectSetting("Faucet.musdPerClaim", MUSD_PER_CLAIM, faucet.musdPerClaim());
        _expectSetting("Faucet.dailyLimit", DAILY_LIMIT, faucet.dailyLimit());
        _expectSetting("Faucet.paused", 0, faucet.paused() ? 1 : 0);
        _expectUnderCap("btcPerClaim", faucet.btcPerClaim(), faucet.MAX_BTC_PER_CLAIM());
        _expectUnderCap("musdPerClaim", faucet.musdPerClaim(), faucet.MAX_MUSD_PER_CLAIM());
        _expectUnderCap("dailyLimit", faucet.dailyLimit(), faucet.MAX_DAILY_LIMIT());
    }

    /// @dev KEEPER_ADDRESS is required: without it C65's keeper check could not be made, so the deploy stops. The
    ///      seed wallets are optional because a wallet that is not in .env is not one this check could confuse, and
    ///      each key is read too, so an address line that does not match its key cannot hide a wallet.
    function _knownWallets() internal view returns (address[] memory wallets) {
        wallets = new address[](8);
        wallets[0] = vm.envAddress("KEEPER_ADDRESS");
        wallets[1] = _addressOfKey("KEEPER_PRIVATE_KEY");
        wallets[2] = vm.envOr("BORROWER_ADDRESS", address(0));
        wallets[3] = _addressOfKey("BORROWER_PRIVATE_KEY");
        wallets[4] = vm.envOr("BORROWER2_ADDRESS", address(0));
        wallets[5] = _addressOfKey("BORROWER2_PRIVATE_KEY");
        wallets[6] = vm.envOr("BUYER_ADDRESS", address(0));
        wallets[7] = _addressOfKey("BUYER_PRIVATE_KEY");
    }

    function _addressOfKey(string memory keyVar) internal view returns (address) {
        uint256 key = vm.envOr(keyVar, uint256(0));
        return key == 0 ? address(0) : vm.addr(key);
    }

    function _wallet(string memory keyVar, string memory addressVar) internal view returns (uint256 key, address account) {
        key = vm.envUint(keyVar);
        account = vm.envAddress(addressVar);
        if (vm.addr(key) != account) revert KeyAddressMismatch(vm.addr(key), account);
    }

    /// @dev Runs first, so a broadcast aimed at an existing record stops with nothing sent. The existence check and
    ///      the write use the same path string, so the file system resolves both the same way.
    function _recordPath() internal view returns (string memory path) {
        string memory name = vm.envOr("DEPLOYMENT_NAME", string(""));
        // forge returns an empty string for a variable set to nothing, so empty falls back to the default too.
        if (bytes(name).length == 0) name = string.concat(vm.toString(block.chainid), "-faucet");
        _checkDeploymentName(name);
        path = string.concat("deployments/", name, ".json");
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && vm.exists(path)) {
            revert RefusingToOverwriteRecord(path);
        }
    }

    /// @dev The name becomes a file name the app looks up, so it is held to letters, digits, dash and underscore: no
    ///      folder separators, no dots, no spaces.
    function _checkDeploymentName(string memory name) internal pure {
        bytes memory raw = bytes(name);
        if (raw.length > MAX_NAME_BYTES) revert BadDeploymentName(name);
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            bool ok = (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "-" || c == "_";
            if (!ok) revert BadDeploymentName(name);
        }
    }

    function _expect(string memory what, address expected, address actual) internal pure {
        if (expected != actual) revert WiringMismatch(what, expected, actual);
    }

    function _expectSetting(string memory what, uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert SettingMismatch(what, expected, actual);
    }

    function _expectUnderCap(string memory what, uint256 value, uint256 cap) internal pure {
        if (value > cap) revert SettingAboveCap(what, value, cap);
    }

    /// @dev Only a broadcast writes the record, because other scripts and the app trust it.
    function _record(string memory path, Faucet faucet, address deployer, address relayer) internal {
        if (!vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) {
            console.log("dry run: no record written");
            return;
        }
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeBool(obj, "broadcast", true);
        vm.serializeUint(obj, "block", block.number);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "owner", deployer);
        vm.serializeAddress(obj, "relayer", relayer);
        vm.serializeAddress(obj, "musd", MUSD);
        vm.serializeUint(obj, "btcPerClaim", BTC_PER_CLAIM);
        vm.serializeUint(obj, "musdPerClaim", MUSD_PER_CLAIM);
        vm.serializeUint(obj, "dailyLimit", DAILY_LIMIT);
        string memory json = vm.serializeAddress(obj, "faucet", address(faucet));
        vm.writeJson(json, path);
        console.log("wrote", path);
    }
}
