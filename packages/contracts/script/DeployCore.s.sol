// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {CreditMarkets} from "../src/CreditMarkets.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {ILoanManager} from "../src/interfaces/ILoanManager.sol";
import {IVeBTC} from "../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

/// @title DeployCore
/// @notice Deploys CreditMarkets and LoanManager to Mezo testnet in two transactions and records the
///         addresses in deployments/<chainId>.json. The file's "broadcast" field is false after a dry run, when
///         the addresses are only the ones the next two deployer transactions would produce.
/// @dev Dry run: forge script script/DeployCore.s.sol --rpc-url mezo_testnet
///      Deploy:  forge script script/DeployCore.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow
///      Rehearse first on an anvil fork with script/rehearse-live.sh, which uses the same flags.
///      Reads DEPLOYER_PRIVATE_KEY and DEPLOYER_ADDRESS from .env, and DEPLOYMENTS_DIR if set (the rehearsal
///      only). The deployer is owner, guardian and treasury. Risk settings are the drawdown study's
///      (docs/risk/parameters.md): 40% borrow limit, 65% line, auction floor 70% of the start value over 72 hours,
///      and a 5% penalty. Mainnet is refused on purpose: this build has no mainnet budget.
contract DeployCore is Script {
    struct ChainConfig {
        address veBTC;
        address musd;
        address btc;
        address priceFeed;
        address poolsVoter;
        uint256 lockLayoutWords;
    }

    uint256 internal constant TESTNET_CHAIN_ID = 31_611;
    uint256 internal constant WEEK = 604_800;
    uint16 internal constant MAX_LTV_BPS = 4_000;
    uint16 internal constant LIQ_LTV_BPS = 6_500;
    uint16 internal constant AUCTION_FLOOR_BPS = 7_000;
    uint32 internal constant AUCTION_DURATION = 72 hours;
    uint16 internal constant PENALTY_BPS = 500;
    uint128 internal constant MIN_LOAN = 10e18;
    uint16 internal constant FEE_SHARE_BPS = 1_000;
    uint128 internal constant MIN_OFFER = 10e18;
    uint32 internal constant MAX_TERM_SECONDS = uint32(4 * WEEK);

    uint256 internal constant MAX_PROBE_IDS = 50;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;

    error UnsupportedChain(uint256 chainId);
    error KeyAddressMismatch(address fromKey, address configured);
    error MissingCode(address target);
    error LockLayoutMismatch(uint256 tokenId, uint256 returnedBytes);
    error LockEndNotOnWeek(uint256 tokenId, uint256 end);
    error NoProbeToken(uint256 triedUpTo);
    error PriceOutOfRange(uint256 price);
    error AddressPredictionFailed(address predicted, address deployed);
    error VoterMismatch(address veBTCVoter, address configured);

    function run() public virtual {
        (uint256 key, address deployer) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        ChainConfig memory cfg = _config();
        (CreditMarkets cm, LoanManager lm) = _deployCore(cfg, key, deployer);
        _record(cfg, cm, lm, deployer);
    }

    function _config() internal view returns (ChainConfig memory) {
        if (block.chainid != TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
        // poolsVoter is testnet veBTC.voter(), read on 2026-10-19; _preflight re-reads it and refuses a mismatch.
        return ChainConfig({
            veBTC: 0xB63fcCd03521Cf21907627bd7fA465C129479231,
            musd: 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503,
            btc: 0x7b7C000000000000000000000000000000000000,
            priceFeed: 0x86bCF0841622a5dAC14A313a15f96A95421b9366,
            poolsVoter: 0x72F8dd7F44fFa19E45955aa20A5486E8EB255738,
            lockLayoutWords: 3
        });
    }

    /// @dev An anvil fork of testnet also reports chain id 31611, so a rehearsal writing here would replace the
    ///      real testnet record with addresses that exist only on anvil. rehearse-live.sh points this elsewhere.
    function _deploymentsDir() internal view returns (string memory) {
        return vm.envOr("DEPLOYMENTS_DIR", string("deployments"));
    }

    function _wallet(string memory keyVar, string memory addressVar) internal view returns (uint256 key, address account) {
        key = vm.envUint(keyVar);
        account = vm.envAddress(addressVar);
        if (vm.addr(key) != account) revert KeyAddressMismatch(vm.addr(key), account);
    }

    /// @dev Fails the deploy unless the chain looks as LoanManager expects (threat model C22): every outside
    ///      address has code, veBTC's own voter is the PoolsVoter configured here, a live lock decodes with this
    ///      chain's layout and ends on a week boundary, and the oracle answers with a sane 18-decimal price.
    ///      CreditMarkets and LoanManager pointing at each other and sharing MUSD and BTC (C27) is enforced by
    ///      LoanManager's constructor.
    function _deployCore(ChainConfig memory cfg, uint256 key, address deployer)
        internal
        returns (CreditMarkets cm, LoanManager lm)
    {
        _preflight(cfg);

        vm.startBroadcast(key);
        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        cm = new CreditMarkets(
            cfg.musd, cfg.btc, predicted, deployer, deployer, deployer, FEE_SHARE_BPS, MIN_OFFER, MAX_TERM_SECONDS
        );
        lm = new LoanManager(
            cfg.veBTC,
            cfg.priceFeed,
            cfg.musd,
            cfg.btc,
            cfg.poolsVoter,
            address(cm),
            cfg.lockLayoutWords,
            _settings(deployer)
        );
        vm.stopBroadcast();

        if (address(lm) != predicted) revert AddressPredictionFailed(predicted, address(lm));
        console.log("CreditMarkets", address(cm));
        console.log("LoanManager  ", address(lm));
    }

    function _settings(address deployer) internal pure returns (ILoanManager.Settings memory) {
        return ILoanManager.Settings({
            owner: deployer,
            guardian: deployer,
            maxLtvBps: MAX_LTV_BPS,
            liqLtvBps: LIQ_LTV_BPS,
            minLoan: MIN_LOAN,
            penaltyBps: PENALTY_BPS,
            auctionFloorBps: AUCTION_FLOOR_BPS,
            auctionDuration: AUCTION_DURATION
        });
    }

    function _preflight(ChainConfig memory cfg) internal {
        address[5] memory targets = [cfg.veBTC, cfg.musd, cfg.btc, cfg.priceFeed, cfg.poolsVoter];
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i].code.length == 0) revert MissingCode(targets[i]);
        }
        (bool ok, bytes memory raw) = cfg.veBTC.staticcall(abi.encodeWithSignature("voter()"));
        address veVoter = ok && raw.length == 32 ? abi.decode(raw, (address)) : address(0);
        if (veVoter != cfg.poolsVoter) revert VoterMismatch(veVoter, cfg.poolsVoter);
        uint256 probeId = _probeLockLayout(cfg);
        uint256 price = _priceOnNode(cfg.priceFeed);
        if (price < MIN_BTC_PRICE || price > MAX_BTC_PRICE) revert PriceOutOfRange(price);
        console.log("preflight: lock layout ok on tokenId", probeId);
        console.log("preflight: BTC price (18 dp)", price);
    }

    function _probeLockLayout(ChainConfig memory cfg) internal view returns (uint256) {
        for (uint256 id = 1; id <= MAX_PROBE_IDS; ++id) {
            if (IVeBTC(cfg.veBTC).ownerOf(id) == address(0)) continue;
            (bool ok, bytes memory raw) = cfg.veBTC.staticcall(abi.encodeWithSignature("locked(uint256)", id));
            if (!ok || raw.length != cfg.lockLayoutWords * 32) revert LockLayoutMismatch(id, raw.length);
            (int128 amount, uint256 end,) = abi.decode(raw, (int128, uint256, bool));
            if (amount <= 0) continue;
            if (end % WEEK != 0) revert LockEndNotOnWeek(id, end);
            return id;
        }
        revert NoProbeToken(MAX_PROBE_IDS);
    }

    /// @dev PriceFeed reads Mezo's Skip oracle precompile, which a local EVM cannot execute, so the node
    ///      answers. A stale oracle makes the node's call revert, which fails the deploy.
    function _priceOnNode(address feed) internal returns (uint256) {
        string memory params = string.concat(
            '[{"to":"',
            vm.toString(feed),
            '","data":"',
            vm.toString(abi.encodeWithSelector(IPriceFeed.fetchPrice.selector)),
            '"},"latest"]'
        );
        return abi.decode(vm.rpc("eth_call", params), (uint256));
    }

    function _record(ChainConfig memory cfg, CreditMarkets cm, LoanManager lm, address deployer) internal {
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        string memory obj = "deployment";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeBool(obj, "broadcast", broadcast);
        vm.serializeUint(obj, "block", block.number);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "veBTC", cfg.veBTC);
        vm.serializeAddress(obj, "musd", cfg.musd);
        vm.serializeAddress(obj, "btc", cfg.btc);
        vm.serializeAddress(obj, "priceFeed", cfg.priceFeed);
        vm.serializeAddress(obj, "poolsVoter", cfg.poolsVoter);
        vm.serializeUint(obj, "lockLayoutWords", cfg.lockLayoutWords);
        vm.serializeAddress(obj, "creditMarkets", address(cm));
        string memory json = vm.serializeAddress(obj, "loanManager", address(lm));

        string memory dir = _deploymentsDir();
        vm.createDir(dir, true);
        string memory path = string.concat(dir, "/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console.log("wrote", path, broadcast ? "(broadcast)" : "(dry run: no code at these addresses yet)");
    }
}
