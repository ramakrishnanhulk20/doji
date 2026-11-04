// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {CreditMarkets} from "../src/CreditMarkets.sol";
import {LoanManager} from "../src/LoanManager.sol";
import {PayDown} from "../src/PayDown.sol";
import {UnitMarket} from "../src/UnitMarket.sol";
import {PassThrough} from "../src/libraries/PassThrough.sol";
import {ILoanManager} from "../src/interfaces/ILoanManager.sol";
import {IMezoRouter} from "../src/interfaces/IMezoRouter.sol";
import {IMUSDSavingsRate} from "../src/interfaces/IMUSDSavingsRate.sol";
import {IVeBTC} from "../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";

/// @title DeployCore
/// @notice Deploys CreditMarkets and LoanManager, then PayDown and UnitMarket on top of them, to Mezo testnet in
///         four transactions, against a PassThrough library already deployed, and records every address in
///         deployments/<DEPLOYMENT_NAME>.json (the name defaults to the chain id). A dry run writes
///         deployments/<DEPLOYMENT_NAME>.dryrun.json instead. A broadcast refuses to start if its record file
///         already exists, so the 20 Oct record, deployments/31611.json, can never be overwritten.
/// @dev Dry run: DEPLOYMENT_NAME=31611-wave2 forge script script/DeployCore.s.sol --rpc-url mezo_testnet
///      Deploy, in two steps so the explorer indexes the library's own creation and can verify it, from
///      packages/contracts with .env loaded (set -a; source .env; set +a):
///        P=$(cast compute-address "$DEPLOYER_ADDRESS" --nonce $(cast nonce "$DEPLOYER_ADDRESS" --rpc-url mezo_testnet) | awk '{print $NF}')
///        forge create src/libraries/PassThrough.sol:PassThrough --rpc-url mezo_testnet --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast --libraries src/libraries/PassThrough.sol:PassThrough:$P
///        DEPLOYMENT_NAME=31611-wave2 forge script script/DeployCore.s.sol --rpc-url mezo_testnet --broadcast --skip-simulation --slow --sender "$DEPLOYER_ADDRESS" --libraries src/libraries/PassThrough.sol:PassThrough:$P
///      Both commands take the same --libraries setting because solc writes it into the metadata hash at the end
///      of the library's code, so the hash check below only matches a library compiled with it. A broadcast is
///      refused unless --sender is the deployer (_checkSingleRun).
///      Before deploying anything, the script refuses a PassThrough address with no code or whose runtime code
///      differs from the compiled artifact, and records the library and its code hash. It also runs the C51
///      checks (_preflightPeriphery) before the first transaction and reads every new contract back after the
///      last (_checkDeployed); forge sends nothing unless the whole run, read-back included, passes.
///      Rehearse first on an anvil fork with script/rehearse-wave2.sh, which uses the same flags.
///      Reads DEPLOYER_PRIVATE_KEY, DEPLOYER_ADDRESS and KEEPER_ADDRESS from .env, and if set DEPLOYMENT_NAME,
///      DEPLOYMENTS_DIR (rehearse-live.sh only), SAVINGS_VAULT and ROUTER (else the chain's own vault and pool
///      Router), PAYDOWN_SLIPPAGE_BPS (else 100, cap 300) and UNIT_FEE_BPS (else 25, cap 100). The deployer is
///      owner, guardian and treasury of all four contracts. Risk settings are the drawdown study's
///      (docs/risk/parameters.md): 40% borrow limit, 65% line, auction floor 70% of the start value over 72 hours,
///      and a 5% penalty. A vote may list up to 30 pools, PoolsVoter's own limit. ValidatorsVoter is read from
///      what testnet's veBTC really has (none today). The credit units start with an
///      empty metadata URI until the app serves metadata; the owner sets it with setURI. Without --libraries
///      (a dry run or the rehearsal) forge deploys PassThrough itself through the standard CREATE2 deployer, and
///      the same code check runs on that copy. The address check after deployment proves the LoanManager
///      prediction still held. Mainnet is refused on purpose: this build has no mainnet budget.
contract DeployCore is Script {
    using SafeCast for uint256;

    struct ChainConfig {
        address veBTC;
        address musd;
        address btc;
        address priceFeed;
        address poolsVoter;
        address validatorsVoter;
        address feeDistributor;
        uint256 lockLayoutWords;
        address savingsVault;
    }

    /// @dev The two settings stay full width until the cap check, so a value such as 65,636 can never wrap to a
    ///      small number on its way into a uint16.
    struct PeripheryConfig {
        address router;
        uint256 slippageBps;
        uint256 unitFeeBps;
        address keeper;
    }

    struct Deployed {
        CreditMarkets creditMarkets;
        LoanManager loanManager;
        PayDown payDown;
        UnitMarket unitMarket;
    }

    uint256 internal constant TESTNET_CHAIN_ID = 31_611;
    uint256 internal constant MAINNET_CHAIN_ID = 31_612;
    address internal constant TESTNET_SAVINGS_VAULT = 0x6f461c68B2c5492C0F5CCEc5a264d692aA7A8e16;
    address internal constant MAINNET_SAVINGS_VAULT = 0xb4D498029af77680cD1eF828b967f010d06C51CC;
    /// @dev Mezo's pool Routers; both answered defaultFactory() on 2026-11-04.
    address internal constant TESTNET_ROUTER = 0x9a1ff7FE3a0F69959A3fBa1F1e5ee18e1A9CD7E9;
    address internal constant MAINNET_ROUTER = 0x16A76d3cd3C1e3CE843C6680d6B37E9116b5C706;
    uint256 internal constant DEFAULT_PAYDOWN_SLIPPAGE_BPS = 100;
    uint256 internal constant DEFAULT_UNIT_FEE_BPS = 25;
    /// @dev Copies of PayDown.MAX_SLIPPAGE_BPS and UnitMarket.MAX_FEE_BPS: Solidity cannot read another
    ///      contract's constant before that contract exists. The read-back compares each copy with the deployed
    ///      contract's own cap, so a cap changed in src without updating this fails the deploy.
    uint256 internal constant PAYDOWN_SLIPPAGE_CAP_BPS = 300;
    uint256 internal constant UNIT_FEE_CAP_BPS = 100;
    /// @dev The 20 Oct pair's record, which the app's address book is built from. It is read before anything is
    ///      deployed and again after the new record is written, and the deploy fails if one byte differs.
    string internal constant LIVE_RECORD = "deployments/31611.json";
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
    uint16 internal constant MAX_VOTES = 30;
    string internal constant UNITS_URI = "";

    uint256 internal constant MAX_NAME_BYTES = 64;
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
    error NoFeeDistributor(address veBTC);
    error SecondaryVotersUnknown(address veBTC);
    error NotSecondaryVoter(address voter);
    error MissingLibrary(address library_);
    error LibraryCodeMismatch(address library_, bytes32 deployedHash, bytes32 expectedHash);
    error RefusingToOverwriteRecord(string path);
    error BadDeploymentName(string name);
    error SenderNotDeployer(address sender, address deployer);
    error SettingAboveCap(string setting, uint256 value, uint256 cap);
    error MissingKeeper();
    error KeeperHoldsRole(address keeper, address target);
    error WiringMismatch(string what, address expected, address actual);
    error SettingMismatch(string what, uint256 expected, uint256 actual);
    error LiveRecordChanged(string path, bytes32 before, bytes32 afterwards);

    function run() public virtual {
        string memory path = _recordPath();
        (uint256 key, address deployer) = _wallet("DEPLOYER_PRIVATE_KEY", "DEPLOYER_ADDRESS");
        _checkSingleRun(deployer);
        ChainConfig memory cfg = _config();
        PeripheryConfig memory extra = _peripheryConfig();
        bytes32 liveRecord = _liveRecordHash();
        _preflightPeriphery(cfg, extra, deployer);
        Deployed memory d;
        (d.creditMarkets, d.loanManager) = _deployCore(cfg, key, deployer);
        (d.payDown, d.unitMarket) = _deployPeriphery(d, extra, key, deployer);
        _checkDeployed(cfg, extra, d);
        _record(path, cfg, extra, d, deployer);
        _checkLiveRecordUntouched(liveRecord);
    }

    /// @dev KEEPER_ADDRESS is required: without it the role check below could not be made, so the deploy stops.
    function _peripheryConfig() internal view returns (PeripheryConfig memory) {
        return PeripheryConfig({
            router: _router(),
            slippageBps: vm.envOr("PAYDOWN_SLIPPAGE_BPS", DEFAULT_PAYDOWN_SLIPPAGE_BPS),
            unitFeeBps: vm.envOr("UNIT_FEE_BPS", DEFAULT_UNIT_FEE_BPS),
            keeper: vm.envAddress("KEEPER_ADDRESS")
        });
    }

    /// @dev C51 before any transaction, on top of C22 (_preflight, which _deployCore runs next): the sMUSD vault
    ///      has code and takes this MUSD, the Router has code and so does its default factory, the slippage
    ///      allowance and unit fee are within the contracts' caps, and the keeper is none of the roles. The
    ///      deployer is every contract's owner, guardian and treasury, so the keeper must not be the deployer;
    ///      _checkDeployed then reads every role back from the contracts themselves.
    function _preflightPeriphery(ChainConfig memory cfg, PeripheryConfig memory extra, address deployer) internal view {
        if (cfg.savingsVault.code.length == 0) revert MissingCode(cfg.savingsVault);
        address vaultToken = _readAddress(cfg.savingsVault, IMUSDSavingsRate.musdToken.selector);
        if (vaultToken != cfg.musd) revert WiringMismatch("sMUSD vault musdToken()", cfg.musd, vaultToken);
        if (extra.router.code.length == 0) revert MissingCode(extra.router);
        address factory = _readAddress(extra.router, IMezoRouter.defaultFactory.selector);
        if (factory.code.length == 0) revert MissingCode(factory);
        if (extra.slippageBps > PAYDOWN_SLIPPAGE_CAP_BPS) {
            revert SettingAboveCap("PAYDOWN_SLIPPAGE_BPS", extra.slippageBps, PAYDOWN_SLIPPAGE_CAP_BPS);
        }
        if (extra.unitFeeBps > UNIT_FEE_CAP_BPS) {
            revert SettingAboveCap("UNIT_FEE_BPS", extra.unitFeeBps, UNIT_FEE_CAP_BPS);
        }
        if (extra.keeper == address(0)) revert MissingKeeper();
        if (extra.keeper == deployer) revert KeeperHoldsRole(extra.keeper, deployer);
        console.log("preflight: sMUSD vault takes MUSD", cfg.savingsVault);
        console.log("preflight: Router and its factory have code", extra.router, factory);
        console.log("preflight: slippage bps / unit fee bps", extra.slippageBps, extra.unitFeeBps);
        console.log("preflight: keeper is not the deployer", extra.keeper);
    }

    /// @dev C51 after deployment, read from the new contracts rather than from what this script passed in. Every
    ///      call here runs in forge's local run, before anything is sent, so a failure here sends nothing.
    function _checkDeployed(ChainConfig memory cfg, PeripheryConfig memory extra, Deployed memory d) internal view {
        CreditMarkets cm = d.creditMarkets;
        LoanManager lm = d.loanManager;
        PayDown pd = d.payDown;
        UnitMarket um = d.unitMarket;
        _expect("CreditMarkets.savingsVault", cfg.savingsVault, cm.savingsVault());
        _expect("CreditMarkets.loanManager", address(lm), cm.loanManager());
        _expect("LoanManager.creditMarkets", address(cm), address(lm.creditMarkets()));
        _expect("PayDown.loanManager", address(lm), address(pd.loanManager()));
        _expect("PayDown.router", extra.router, address(pd.router()));
        _expect("PayDown.factory", _readAddress(extra.router, IMezoRouter.defaultFactory.selector), pd.factory());
        _expect("PayDown.musd", cfg.musd, address(pd.musd()));
        _expect("PayDown.btc", cfg.btc, address(pd.btc()));
        _expect("PayDown.priceFeed", cfg.priceFeed, address(pd.priceFeed()));
        _expect("UnitMarket.creditMarkets", address(cm), um.creditMarkets());
        _expect("UnitMarket.musd", cfg.musd, um.musd());
        _expectSetting("PayDown.MAX_SLIPPAGE_BPS", PAYDOWN_SLIPPAGE_CAP_BPS, pd.MAX_SLIPPAGE_BPS());
        _expectSetting("PayDown.slippageBps", extra.slippageBps, pd.slippageBps());
        _expectSetting("UnitMarket.MAX_FEE_BPS", UNIT_FEE_CAP_BPS, um.MAX_FEE_BPS());
        _expectSetting("UnitMarket.feeBps", extra.unitFeeBps, um.feeBps());
        _checkKeeperHoldsNoRole(extra.keeper, d);
        console.log("read-back: C51 addresses, caps, settings and keeper roles match");
    }

    /// @dev Ten fixed reads, every owner, guardian and treasury the four contracts have. LoanManager has no
    ///      treasury of its own: it pays CreditMarkets' treasury, which is read here.
    function _checkKeeperHoldsNoRole(address keeper, Deployed memory d) internal view {
        address cm = address(d.creditMarkets);
        address lm = address(d.loanManager);
        address pd = address(d.payDown);
        address um = address(d.unitMarket);
        address[10] memory holders = [cm, cm, cm, lm, lm, pd, pd, um, um, um];
        address[10] memory roles = [
            d.creditMarkets.owner(),
            d.creditMarkets.guardian(),
            d.creditMarkets.treasury(),
            d.loanManager.owner(),
            d.loanManager.guardian(),
            d.payDown.owner(),
            d.payDown.guardian(),
            d.unitMarket.owner(),
            d.unitMarket.guardian(),
            d.unitMarket.treasury()
        ];
        for (uint256 i; i < roles.length; ++i) {
            if (roles[i] == keeper) revert KeeperHoldsRole(keeper, holders[i]);
        }
    }

    /// @dev Zero when this chain has no live record yet, which happens only on a first deployment.
    function _liveRecordHash() internal view returns (bytes32) {
        if (!vm.exists(LIVE_RECORD)) {
            console.log("preflight: no", LIVE_RECORD, "here to protect");
            return bytes32(0);
        }
        string memory json = vm.readFile(LIVE_RECORD);
        console.log(
            "preflight: live pair kept as is",
            vm.parseJsonAddress(json, ".creditMarkets"),
            vm.parseJsonAddress(json, ".loanManager")
        );
        return keccak256(bytes(json));
    }

    function _checkLiveRecordUntouched(bytes32 before) internal view {
        if (before == bytes32(0)) return;
        bytes32 afterwards = vm.exists(LIVE_RECORD) ? keccak256(bytes(vm.readFile(LIVE_RECORD))) : bytes32(0);
        if (afterwards != before) revert LiveRecordChanged(LIVE_RECORD, before, afterwards);
        console.log("read-back:", LIVE_RECORD, "unchanged");
    }

    /// @dev A target that reverts or answers in another shape reads as the zero address, which every caller
    ///      then refuses.
    function _readAddress(address target, bytes4 selector) internal view returns (address value) {
        (bool ok, bytes memory raw) = target.staticcall(abi.encodeWithSelector(selector));
        if (ok && raw.length == 32) value = abi.decode(raw, (address));
    }

    function _expect(string memory what, address expected, address actual) internal pure {
        if (expected != actual) revert WiringMismatch(what, expected, actual);
    }

    function _expectSetting(string memory what, uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert SettingMismatch(what, expected, actual);
    }

    function _router() internal view returns (address) {
        address chainDefault = block.chainid == TESTNET_CHAIN_ID
            ? TESTNET_ROUTER
            : block.chainid == MAINNET_CHAIN_ID ? MAINNET_ROUTER : address(0);
        return vm.envOr("ROUTER", chainDefault);
    }

    /// @dev After the pair, because PayDown reads MUSD, BTC and PriceFeed from the new LoanManager and UnitMarket
    ///      reads MUSD from the new CreditMarkets, so neither can be pointed at the old pair (C27). The deployer
    ///      holds every role, as it does for the pair.
    function _deployPeriphery(Deployed memory d, PeripheryConfig memory extra, uint256 key, address deployer)
        internal
        returns (PayDown payDown, UnitMarket unitMarket)
    {
        vm.startBroadcast(key);
        payDown = new PayDown(address(d.loanManager), extra.router, deployer, deployer, extra.slippageBps.toUint16());
        unitMarket = new UnitMarket(address(d.creditMarkets), deployer, deployer, deployer, extra.unitFeeBps.toUint16());
        vm.stopBroadcast();
        console.log("PayDown      ", address(payDown));
        console.log("UnitMarket   ", address(unitMarket));
    }

    /// @dev Runs first, before any other check or transaction, so a broadcast aimed at an existing record stops
    ///      with nothing sent. The existence check and the write use the same path string, so the file system
    ///      resolves both the same way, whatever its case rules. Only a real record is protected: a dry run may
    ///      replace an older dry run.
    function _recordPath() internal view returns (string memory path) {
        string memory name = vm.envOr("DEPLOYMENT_NAME", string(""));
        // forge returns an empty string for a variable set to nothing, where it falls back for numbers and
        // addresses; treating both the same way lets .env.example leave the name blank.
        if (bytes(name).length == 0) name = vm.toString(block.chainid);
        _checkDeploymentName(name);
        bool broadcast = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        path = string.concat(_deploymentsDir(), "/", name, broadcast ? ".json" : ".dryrun.json");
        if (broadcast && vm.exists(path)) revert RefusingToOverwriteRecord(path);
    }

    /// @dev When forge deploys PassThrough itself (no --libraries) and the broadcaster is not the script's sender,
    ///      it runs this script once, re-links the library against the broadcaster and runs it again. The first
    ///      pass would write the record and the second would then refuse it, leaving a record of contracts that
    ///      were never sent. A broadcast therefore needs --sender "$DEPLOYER_ADDRESS", which makes forge run once.
    function _checkSingleRun(address deployer) internal view {
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) && msg.sender != deployer) {
            revert SenderNotDeployer(msg.sender, deployer);
        }
    }

    /// @dev The name becomes a file name that the app and keeper look up, so it is held to letters, digits, dash
    ///      and underscore: no folder separators, no dots that could forge a ".dryrun" suffix, no spaces.
    function _checkDeploymentName(string memory name) internal pure {
        bytes memory raw = bytes(name);
        if (raw.length > MAX_NAME_BYTES) revert BadDeploymentName(name);
        for (uint256 i; i < raw.length; ++i) {
            bytes1 c = raw[i];
            bool ok = (c >= "0" && c <= "9") || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "-" || c == "_";
            if (!ok) revert BadDeploymentName(name);
        }
    }

    function _config() internal view returns (ChainConfig memory) {
        if (block.chainid != TESTNET_CHAIN_ID) revert UnsupportedChain(block.chainid);
        address veBTC = 0xB63fcCd03521Cf21907627bd7fA465C129479231;
        // poolsVoter is testnet veBTC.voter(), read on 2026-10-19; _preflight re-reads it and refuses a mismatch.
        // The fee distributor is whatever veBTC names now, so the two can never disagree.
        return ChainConfig({
            veBTC: veBTC,
            musd: 0x118917a40FAF1CD7a13dB0Ef56C86De7973Ac503,
            btc: 0x7b7C000000000000000000000000000000000000,
            priceFeed: 0x86bCF0841622a5dAC14A313a15f96A95421b9366,
            poolsVoter: 0x72F8dd7F44fFa19E45955aa20A5486E8EB255738,
            validatorsVoter: _testnetValidatorsVoter(veBTC),
            feeDistributor: _veBTCDistributor(veBTC),
            lockLayoutWords: 3,
            savingsVault: _savingsVault()
        });
    }

    /// @dev Testnet's vault is not the address Mezo's docs list; it is the one testnet PCV pays (feeRecipient()),
    ///      read on 2026-11-03. CreditMarkets' constructor refuses a vault whose musdToken() is not this MUSD.
    function _savingsVault() internal view returns (address) {
        address chainDefault = block.chainid == TESTNET_CHAIN_ID
            ? TESTNET_SAVINGS_VAULT
            : block.chainid == MAINNET_CHAIN_ID ? MAINNET_SAVINGS_VAULT : address(0);
        return vm.envOr("SAVINGS_VAULT", chainDefault);
    }

    /// @dev veBTC cannot list its secondary voters, so this asks whether testnet's veBTC has any at all. Its older
    ///      implementation (checked 2026-10-19) has no isSecondaryVoter, so no ValidatorsVoter can hold a vote and
    ///      LoanManager is given none. If a testnet upgrade adds secondary voters this fails the deploy, because a
    ///      voter left unset could block settle (C5, C26).
    function _testnetValidatorsVoter(address veBTC) internal view returns (address) {
        (bool supported,) = veBTC.staticcall(abi.encodeWithSignature("isSecondaryVoter(address)", address(0)));
        if (supported) revert SecondaryVotersUnknown(veBTC);
        return address(0);
    }

    function _veBTCDistributor(address veBTC) internal view returns (address distributor) {
        (bool ok, bytes memory raw) = veBTC.staticcall(abi.encodeWithSignature("distributor()"));
        distributor = ok && raw.length == 32 ? abi.decode(raw, (address)) : address(0);
        if (distributor == address(0)) revert NoFeeDistributor(veBTC);
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
    ///      address has code, the linked PassThrough library is exactly the compiled one, veBTC's own voter is the
    ///      PoolsVoter configured here, a live lock decodes with this
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
            cfg.musd,
            cfg.btc,
            predicted,
            deployer,
            deployer,
            deployer,
            FEE_SHARE_BPS,
            MIN_OFFER,
            MAX_TERM_SECONDS,
            UNITS_URI,
            cfg.savingsVault
        );
        lm = new LoanManager(
            cfg.veBTC,
            cfg.priceFeed,
            cfg.musd,
            cfg.btc,
            cfg.poolsVoter,
            address(cm),
            cfg.lockLayoutWords,
            _settings(deployer, cfg.feeDistributor, cfg.validatorsVoter)
        );
        vm.stopBroadcast();

        if (address(lm) != predicted) revert AddressPredictionFailed(predicted, address(lm));
        console.log("CreditMarkets", address(cm));
        console.log("LoanManager  ", address(lm));
    }

    function _settings(address deployer, address feeDistributor, address validatorsVoter)
        internal
        pure
        returns (ILoanManager.Settings memory)
    {
        return ILoanManager.Settings({
            owner: deployer,
            guardian: deployer,
            feeDistributor: feeDistributor,
            validatorsVoter: validatorsVoter,
            maxVotes: MAX_VOTES,
            maxLtvBps: MAX_LTV_BPS,
            liqLtvBps: LIQ_LTV_BPS,
            minLoan: MIN_LOAN,
            penaltyBps: PENALTY_BPS,
            auctionFloorBps: AUCTION_FLOOR_BPS,
            auctionDuration: AUCTION_DURATION
        });
    }

    function _preflight(ChainConfig memory cfg) internal {
        address[6] memory targets = [cfg.veBTC, cfg.musd, cfg.btc, cfg.priceFeed, cfg.poolsVoter, cfg.feeDistributor];
        for (uint256 i; i < targets.length; ++i) {
            if (targets[i].code.length == 0) revert MissingCode(targets[i]);
        }
        (bool ok, bytes memory raw) = cfg.veBTC.staticcall(abi.encodeWithSignature("voter()"));
        address veVoter = ok && raw.length == 32 ? abi.decode(raw, (address)) : address(0);
        if (veVoter != cfg.poolsVoter) revert VoterMismatch(veVoter, cfg.poolsVoter);
        if (cfg.validatorsVoter == address(0)) {
            console.log("preflight: veBTC has no secondary voters here; ValidatorsVoter left unset");
        } else {
            if (cfg.validatorsVoter.code.length == 0) revert MissingCode(cfg.validatorsVoter);
            (bool isSecondary, bytes memory answer) =
                cfg.veBTC.staticcall(abi.encodeWithSignature("isSecondaryVoter(address)", cfg.validatorsVoter));
            if (!isSecondary || answer.length != 32 || !abi.decode(answer, (bool))) {
                revert NotSecondaryVoter(cfg.validatorsVoter);
            }
        }
        console.log("preflight: PassThrough code matches the artifact at", address(PassThrough));
        console.logBytes32(_passThroughCodeHash());
        uint256 probeId = _probeLockLayout(cfg);
        uint256 price = _priceOnNode(cfg.priceFeed);
        if (price < MIN_BTC_PRICE || price > MAX_BTC_PRICE) revert PriceOutOfRange(price);
        console.log("preflight: lock layout ok on tokenId", probeId);
        console.log("preflight: BTC price (18 dp)", price);
    }

    /// @dev The PassThrough address the compiler linked into LoanManager must hold exactly the compiled library: the
    ///      artifact's runtime code, with the library's own address written into the PUSH20 at byte 1 that every
    ///      library opens with (zero in the artifact, filled in at deployment so its state-changing functions
    ///      refuse direct calls). Returns the code hash recorded with the deployment.
    function _passThroughCodeHash() internal view returns (bytes32 deployedHash) {
        address library_ = address(PassThrough);
        if (library_.code.length == 0) revert MissingLibrary(library_);
        bytes memory expected = vm.getDeployedCode("PassThrough.sol:PassThrough");
        bytes20 own = bytes20(library_);
        for (uint256 i; i < 20; ++i) {
            expected[1 + i] = own[i];
        }
        deployedHash = keccak256(library_.code);
        bytes32 expectedHash = keccak256(expected);
        if (deployedHash != expectedHash) revert LibraryCodeMismatch(library_, deployedHash, expectedHash);
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

    function _record(
        string memory path,
        ChainConfig memory cfg,
        PeripheryConfig memory extra,
        Deployed memory d,
        address deployer
    ) internal {
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
        vm.serializeAddress(obj, "validatorsVoter", cfg.validatorsVoter);
        vm.serializeAddress(obj, "feeDistributor", cfg.feeDistributor);
        vm.serializeUint(obj, "lockLayoutWords", cfg.lockLayoutWords);
        vm.serializeAddress(obj, "savingsVault", cfg.savingsVault);
        vm.serializeAddress(obj, "router", extra.router);
        vm.serializeAddress(obj, "factory", d.payDown.factory());
        vm.serializeUint(obj, "payDownSlippageBps", extra.slippageBps);
        vm.serializeUint(obj, "unitFeeBps", extra.unitFeeBps);
        vm.serializeAddress(obj, "keeper", extra.keeper);
        vm.serializeAddress(obj, "creditMarkets", address(d.creditMarkets));
        // Forge links this script against the same library address as LoanManager, so explorer verification
        // can read the link from the record instead of the broadcast log.
        vm.serializeAddress(obj, "passThrough", address(PassThrough));
        vm.serializeBytes32(obj, "passThroughCodeHash", _passThroughCodeHash());
        vm.serializeAddress(obj, "payDown", address(d.payDown));
        vm.serializeAddress(obj, "unitMarket", address(d.unitMarket));
        string memory json = vm.serializeAddress(obj, "loanManager", address(d.loanManager));

        // Only a broadcast may write <name>.json, the record other scripts and the app trust; _recordPath chose
        // the path and refused an existing one before anything was deployed.
        vm.createDir(_deploymentsDir(), true);
        vm.writeJson(json, path);
        console.log("wrote", path, broadcast ? "(broadcast)" : "(dry run: no code at these addresses yet)");
    }
}
