// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILoanManager} from "../src/interfaces/ILoanManager.sol";
import {ICreditMarkets} from "../src/interfaces/ICreditMarkets.sol";
import {IPayDown} from "../src/interfaces/IPayDown.sol";
import {IVeBTC} from "../src/interfaces/IVeBTC.sol";
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {MezoBtcStandIn} from "../test/utils/MezoBtcStandIn.sol";
import {IWave1Offers} from "./CoreSliceLive.s.sol";

/// @title ProveIt
/// @notice Proves Doji's promise on the live Mezo testnet deployment with the BORROWER wallet: lock a little
///         Bitcoin, borrow MUSD against it at a fixed rate, show the contracts refuse a stranger and a premature
///         liquidation, repay in full and take the Bitcoin position back. On a Wave 2 pair it also proves the loan
///         reached the borrower as plain MUSD out of an offer parked in Mezo's sMUSD vault, and that PayDown can be
///         named reward operator by the borrower alone and leaves with the position. Run in order by
///         script/prove-it.sh, each step against the record DEPLOYMENT_FILE names (default the Wave 2 pair):
///           borrow()                     prints the live picture, then sends approve and lockAndBorrow
///           nameOperator(id, block)      Wave 2 only: sends setRewardOperator(id, PayDown)
///           checkAndRepay(id, block)     checks the live loan, runs the attacks, then sends repay and withdraw
///           confirmReturned(id, b, r)    checks the debt is cleared and the position is back
///         Each check prints one PASS, FAIL or SKIP line; the Wave 2 checks are labelled W1 to W4.
/// @dev Forge runs every step locally before it broadcasts, and a local EVM cannot run Mezo's BTC precompile or the
///      Skip oracle behind PriceFeed. So the local pass etches MezoBtcStandIn over the BTC address and mocks
///      PriceFeed with the price the node itself returns; the broadcast transactions run on the real chain, sent
///      with --skip-simulation --slow. The checks that matter are read after each broadcast: event logs from the
///      node, eth_call against the node at one pinned block, and a fresh fork of the chain for the next step. The
///      attacks run on that fresh fork, as a stranger, and are never broadcast. Reads BORROWER_PRIVATE_KEY and
///      BORROWER_ADDRESS from .env. What this does NOT prove: auctions, settle and redemption (the keeper and the
///      demo loans cover those), or behaviour under a stale oracle.
contract ProveIt is Script {
    using SafeERC20 for IERC20;

    struct Live {
        ILoanManager lm;
        ICreditMarkets cm;
        IVeBTC veBTC;
        IERC20 musd;
        address btc;
        address priceFeed;
        uint256 borrowerKey;
        address borrower;
        bool wave2;
        address payDown;
    }

    struct Pick {
        uint256 offerId;
        uint16 aprBps;
        uint128 remaining;
        bool parked;
    }

    struct Borrow {
        uint64 maturity;
        uint256 principal;
        uint256 face;
        bytes32 txHash;
    }

    /// @dev W1's readings: which offer the borrow filled, as its Filled event names it, and the node's state at the
    ///      block before the borrow and at the borrow block.
    struct VaultFill {
        uint256 offerId;
        uint256 fills;
        uint256 filled;
        uint256 taken;
        uint256 parkedBefore;
        uint256 parkedAfter;
        uint256 musdRise;
    }

    /// @dev Must match the default of DEPLOYMENT_FILE in prove-it.sh.
    string internal constant DEFAULT_RECORD = "deployments/31611-wave2.json";
    uint256 internal constant TESTNET_CHAIN_ID = 31_611;
    uint256 internal constant WEEK = 604_800;
    uint256 internal constant LOCK_BTC = 0.0005 ether;
    uint256 internal constant MIN_BORROWER_BTC = 0.0008 ether;
    uint256 internal constant MIN_LEAD_TIME = 2 days;
    uint256 internal constant MAX_OFFERS_READ = 50;
    uint256 internal constant MAX_DEMO_LOANS = 10;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant PRICE_SCALE = 1e18;
    uint256 internal constant MIN_BTC_PRICE = 10_000e18;
    uint256 internal constant MAX_BTC_PRICE = 1_000_000e18;

    error NotTestnet(uint256 chainId);
    error NoLiveDeployment(string path);
    error DeploymentMismatch(string what);
    error KeyAddressMismatch(address fromKey, address configured);
    error PriceOutOfRange(uint256 price);
    error BorrowerUnderfunded(uint256 balance, uint256 needed);
    error BorrowsArePaused();
    error MaturityNotOpen(uint64 maturity);
    error NoUsableOffer(uint64 maturity, uint256 minLoan);
    error LoanTooLargeForCollateral(uint256 face, uint256 maxFace);
    error NotEnoughMusdForInterest(uint256 held, uint256 interest);
    error NotEnoughMusdToRepay(uint256 held, uint256 owed);
    error BorrowNotFound(uint256 tokenId, uint256 blockNumber);
    error NotWave2();

    /// @notice Step 1. Prints the live picture, then locks 0.0005 test BTC until the next Thursday at least two days
    ///         away and borrows the minimum loan from the cheapest open offer for that date, in one transaction.
    /// @dev Stops before sending anything if the deployment record and the chain disagree, borrows are paused, the
    ///      date is not open, no offer for it has the minimum loan left, the loan would break the borrow limit at
    ///      the live price, or the borrower lacks the BTC or the MUSD interest. Sends BTC.approve and
    ///      LoanManager.lockAndBorrow from BORROWER.
    function borrow() external {
        Live memory live = _load();
        uint256 price = _standInForLocalRun(live);
        _picture(live, price);

        uint64 maturity = _targetMaturity(live.cm);
        uint128 principal = live.lm.minLoan();
        Pick memory pick = _cheapestOffer(live, maturity, principal);
        (uint256 face,,) = live.cm.quoteFill(principal, pick.aprBps, maturity);
        _requireBorrowable(live, price, principal, face);

        uint256[] memory ids = new uint256[](1);
        uint128[] memory amounts = new uint128[](1);
        (ids[0], amounts[0]) = (pick.offerId, principal);
        // veBTC ends a lock at floor((now + duration) / week) * week; aiming half a week past the maturity keeps that
        // floor on the maturity even if the transaction lands hours after this pass read the clock.
        uint256 duration = maturity + WEEK / 2 - block.timestamp;

        console.log("== The promise: lock Bitcoin, borrow MUSD at a fixed rate");
        console.log(
            string.concat(
                "lock ", _amount(LOCK_BTC, 4), " BTC until ", _date(maturity), ", borrow ", _amount(principal, 2),
                " MUSD from offer ", vm.toString(pick.offerId), pick.parked ? " (parked in sMUSD)" : "", " at ",
                _pct(pick.aprBps), " APR, owe ", _amount(face, 4), " MUSD on ", _date(maturity)
            )
        );
        vm.startBroadcast(live.borrowerKey);
        IERC20(live.btc).forceApprove(address(live.lm), LOCK_BTC);
        live.lm.lockAndBorrow(LOCK_BTC, duration, maturity, ids, amounts, pick.aprBps);
        vm.stopBroadcast();
    }

    /// @notice Wave 2 step, after the borrow. Names PayDown reward operator of the position the borrow step opened,
    ///         the choice that lets the position's pool rewards pay its loan down.
    /// @dev Reverts NotWave2 when the record names no PayDown, and BorrowNotFound unless `borrowBlock` holds this
    ///      borrower's Borrowed event for the position. Sending it twice names the same operator twice, so a resumed
    ///      run may repeat it. Sends LoanManager.setRewardOperator from BORROWER.
    function nameOperator(uint256 tokenId, uint256 borrowBlock) external {
        Live memory live = _load();
        if (!live.wave2) revert NotWave2();
        _borrowedIn(live, tokenId, borrowBlock);
        console.log(
            string.concat("== Naming PayDown ", vm.toString(live.payDown), " reward operator of position ", vm.toString(tokenId))
        );
        vm.startBroadcast(live.borrowerKey);
        live.lm.setRewardOperator(tokenId, live.payDown);
        vm.stopBroadcast();
    }

    /// @notice Step 2. Checks the loan the borrow step opened against the live chain, attacks it as a stranger
    ///         without sending anything, then repays the full debt and takes the position back. On a Wave 2 pair it
    ///         also checks the parked fill (W1), the stranger's setRewardOperator (W2) and PayDown as operator (W3).
    /// @dev `tokenId` and `borrowBlock` come from the borrow step's receipt. Reverts BorrowNotFound unless that
    ///      block holds this borrower's Borrowed event for the position, and NotEnoughMusdToRepay before sending
    ///      anything if the borrower cannot cover the debt. Sends MUSD.approve, LoanManager.repay and
    ///      LoanManager.withdrawCollateral from BORROWER.
    function checkAndRepay(uint256 tokenId, uint256 borrowBlock) external {
        Live memory live = _load();
        _standInForLocalRun(live);
        Borrow memory b = _borrowedIn(live, tokenId, borrowBlock);

        console.log(string.concat("== Checks on live position ", vm.toString(tokenId), ", block ", vm.toString(block.number)));
        _checkMusdArrived(live, borrowBlock, b);
        _checkCustody(live, tokenId, b);
        _checkCollateralValue(live, tokenId);

        console.log("== Attacks, simulated on the live state as a stranger, never sent");
        address stranger = makeAddr("doji-prove-it-stranger");
        _attackWithdraw(live, tokenId, stranger);
        _attackStartAuction(live, tokenId, stranger);
        _attackSettle(live, tokenId, stranger);
        if (live.wave2) {
            console.log("== Wave 2: the sMUSD vault and the reward operator");
            _checkParkedFill(live, borrowBlock, b);
            _attackSetOperator(live, tokenId, stranger);
            _checkOperatorNamed(live, tokenId);
        }

        uint256 owed = live.lm.owedOf(tokenId);
        uint256 held = live.musd.balanceOf(live.borrower);
        if (held < owed) {
            console.log("BORROWER cannot cover the debt yet: send it MUSD, then run prove-it.sh --resume", tokenId, borrowBlock);
            revert NotEnoughMusdToRepay(held, owed);
        }
        console.log(string.concat("== Repaying ", _amount(owed, 4), " MUSD in full and taking the position back"));
        vm.startBroadcast(live.borrowerKey);
        live.musd.forceApprove(address(live.lm), owed);
        live.lm.repay(tokenId, owed);
        live.lm.withdrawCollateral(tokenId);
        vm.stopBroadcast();
    }

    /// @notice Step 3. Checks, on the live chain, that the repayment cleared the whole debt and that the position
    ///         is back with the borrower, and on a Wave 2 pair that its record left with it (W4). Sends nothing.
    /// @dev `repayBlock` comes from the repay step's receipt.
    function confirmReturned(uint256 tokenId, uint256 borrowBlock, uint256 repayBlock) external view {
        Live memory live = _load();
        Borrow memory b = _borrowedIn(live, tokenId, borrowBlock);
        console.log(string.concat("== After the repayment, block ", vm.toString(block.number)));
        _checkRepaid(live, tokenId, repayBlock, b.face);
        _checkReturned(live, tokenId);
        if (live.wave2) _checkRecordDeleted(live, tokenId);
    }

    /// @dev The record is trusted only as far as the chain agrees with it: it is for this chain, both contracts have
    ///      code, point at each other and use the record's veBTC, MUSD, BTC and PriceFeed. A record that names PayDown
    ///      is a Wave 2 pair, the same rule prove-it.sh applies; its PayDown must serve this LoanManager and its
    ///      CreditMarkets must park in the record's sMUSD vault.
    function _load() internal view returns (Live memory live) {
        if (block.chainid != TESTNET_CHAIN_ID) revert NotTestnet(block.chainid);
        string memory path = vm.envOr("DEPLOYMENT_FILE", string(DEFAULT_RECORD));
        if (!vm.exists(path)) revert NoLiveDeployment(path);
        string memory json = vm.readFile(path);
        if (!vm.parseJsonBool(json, ".broadcast")) revert NoLiveDeployment(path);
        if (vm.parseJsonUint(json, ".chainId") != block.chainid) revert DeploymentMismatch("the record is for another chain");
        live.lm = ILoanManager(vm.parseJsonAddress(json, ".loanManager"));
        live.cm = ICreditMarkets(vm.parseJsonAddress(json, ".creditMarkets"));
        live.veBTC = IVeBTC(vm.parseJsonAddress(json, ".veBTC"));
        live.musd = IERC20(vm.parseJsonAddress(json, ".musd"));
        live.btc = vm.parseJsonAddress(json, ".btc");
        live.priceFeed = vm.parseJsonAddress(json, ".priceFeed");
        if (address(live.lm).code.length == 0 || address(live.cm).code.length == 0) revert NoLiveDeployment(path);
        if (address(live.lm.creditMarkets()) != address(live.cm) || live.cm.loanManager() != address(live.lm)) {
            revert DeploymentMismatch("LoanManager and CreditMarkets do not point at each other");
        }
        if (
            address(live.lm.veBTC()) != address(live.veBTC) || address(live.lm.musd()) != address(live.musd)
                || address(live.lm.btc()) != live.btc || address(live.lm.priceFeed()) != live.priceFeed
        ) revert DeploymentMismatch("LoanManager uses other Mezo contracts than the record");
        if (vm.keyExistsJson(json, ".payDown")) {
            live.wave2 = true;
            live.payDown = vm.parseJsonAddress(json, ".payDown");
            if (
                live.payDown.code.length == 0 || address(IPayDown(live.payDown).loanManager()) != address(live.lm)
                    || live.cm.savingsVault() != vm.parseJsonAddress(json, ".savingsVault")
            ) revert DeploymentMismatch("PayDown or the sMUSD vault does not match the record");
        }

        live.borrowerKey = vm.envUint("BORROWER_PRIVATE_KEY");
        live.borrower = vm.envAddress("BORROWER_ADDRESS");
        if (vm.addr(live.borrowerKey) != live.borrower) revert KeyAddressMismatch(vm.addr(live.borrowerKey), live.borrower);
    }

    function _standInForLocalRun(Live memory live) internal returns (uint256 price) {
        vm.etch(live.btc, type(MezoBtcStandIn).runtimeCode);
        price = abi.decode(_ethCall(live.priceFeed, abi.encodeCall(IPriceFeed.fetchPrice, ()), "latest"), (uint256));
        if (price < MIN_BTC_PRICE || price > MAX_BTC_PRICE) revert PriceOutOfRange(price);
        vm.mockCall(live.priceFeed, abi.encodeCall(IPriceFeed.fetchPrice, ()), abi.encode(price));
    }

    function _picture(Live memory live, uint256 price) internal view {
        console.log("== Live picture on Mezo testnet");
        console.log(string.concat("block ", vm.toString(block.number), ", ", _dateTime(block.timestamp)));
        console.log(string.concat("BTC price from the oracle: ", _amount(price, 2), " MUSD"));
        console.log(string.concat("LoanManager ", vm.toString(address(live.lm)), ", CreditMarkets ", vm.toString(address(live.cm))));
        if (live.wave2) {
            console.log(
                string.concat(
                    "PayDown ", vm.toString(live.payDown), ", MUSD parked in Mezo's sMUSD vault: ",
                    _amount(live.cm.parkedPrincipal(), 2)
                )
            );
        }
        _printOffers(live);
        _printDemoLoans(live);
    }

    function _printOffers(Live memory live) internal view {
        uint256 next = live.cm.nextOfferId();
        if (next <= 1) {
            console.log("== Open offers: none posted yet");
            return;
        }
        uint256 first = next > MAX_OFFERS_READ ? next - MAX_OFFERS_READ : 1;
        console.log(string.concat("== Open offers per maturity (offer ids ", vm.toString(first), " to ", vm.toString(next - 1), ")"));
        ICreditMarkets.Offer[] memory offers = new ICreditMarkets.Offer[](next - first);
        uint64[] memory maturities = new uint64[](next - first);
        uint256 distinct;
        for (uint256 id = first; id < next; ++id) {
            ICreditMarkets.Offer memory o = _offerOf(live, id);
            offers[id - first] = o;
            if (!_isOpen(o)) continue;
            distinct = _insertSorted(maturities, distinct, o.maturity);
        }
        if (distinct == 0) console.log("none open");
        for (uint256 i; i < distinct; ++i) {
            (uint256 count, uint256 total) = _tally(offers, maturities[i]);
            console.log(
                string.concat(_date(maturities[i]), ": ", vm.toString(count), " offer(s), ", _amount(total, 2), " MUSD to lend")
            );
            for (uint256 j; j < offers.length; ++j) {
                if (!_isOpen(offers[j]) || offers[j].maturity != maturities[i]) continue;
                console.log(
                    string.concat(
                        "  offer ", vm.toString(first + j), " at ", _pct(offers[j].aprBps), " APR, ",
                        _amount(offers[j].remaining, 2), " MUSD left", offers[j].parked ? ", parked in sMUSD" : ""
                    )
                );
            }
        }
    }

    /// @dev Wave 2's offerOf adds the parked flag as a fifth field. The 20 October CreditMarkets returns four, and
    ///      decoding those as five reverts, so each pair is read in its own shape; a 20 October offer is never parked.
    function _offerOf(Live memory live, uint256 id) internal view returns (ICreditMarkets.Offer memory o) {
        if (live.wave2) return live.cm.offerOf(id);
        IWave1Offers.Offer memory old = IWave1Offers(address(live.cm)).offerOf(id);
        o = ICreditMarkets.Offer({
            maker: old.maker, maturity: old.maturity, aprBps: old.aprBps, remaining: old.remaining, parked: false
        });
    }

    /// @dev The 20 October positionOf returns the borrower alone and Wave 2's adds the reward operator after it, so
    ///      only the first word, the borrower on both, is read here.
    function _positionBorrower(Live memory live, uint256 tokenId) internal view returns (address) {
        (bool ok, bytes memory data) = address(live.lm).staticcall(abi.encodeCall(ILoanManager.positionOf, (tokenId)));
        if (!ok || data.length < 32) revert DeploymentMismatch("positionOf did not answer");
        return abi.decode(data, (address));
    }

    function _isOpen(ICreditMarkets.Offer memory o) internal view returns (bool) {
        return o.maker != address(0) && o.remaining != 0 && o.maturity > block.timestamp;
    }

    function _insertSorted(uint64[] memory list, uint256 len, uint64 value) internal pure returns (uint256) {
        uint256 at = len;
        for (uint256 i; i < len; ++i) {
            if (list[i] == value) return len;
            if (list[i] > value && at == len) at = i;
        }
        for (uint256 i = len; i > at; --i) {
            list[i] = list[i - 1];
        }
        list[at] = value;
        return len + 1;
    }

    function _tally(ICreditMarkets.Offer[] memory offers, uint64 maturity) internal view returns (uint256 count, uint256 total) {
        for (uint256 j; j < offers.length; ++j) {
            if (!_isOpen(offers[j]) || offers[j].maturity != maturity) continue;
            ++count;
            total += offers[j].remaining;
        }
    }

    /// @dev Reads the loans SeedDemo recorded, only when that record is a broadcast one for this LoanManager.
    function _printDemoLoans(Live memory live) internal view {
        string memory path = string.concat("deployments/", vm.toString(block.chainid), "-demo.json");
        if (!vm.exists(path)) {
            console.log("== Demo loans: no demo record yet");
            return;
        }
        string memory json = vm.readFile(path);
        if (!vm.keyExistsJson(json, ".loans") || !vm.keyExistsJson(json, ".loanManager") || !vm.keyExistsJson(json, ".broadcast")) {
            console.log("== Demo loans: the demo record has no loans section, skipped");
            return;
        }
        if (!vm.parseJsonBool(json, ".broadcast") || vm.parseJsonAddress(json, ".loanManager") != address(live.lm)) {
            console.log("== Demo loans: the demo record is a dry run or for another LoanManager, skipped");
            return;
        }
        string[] memory names = vm.parseJsonKeys(json, ".loans");
        console.log("== Demo loans");
        for (uint256 i; i < names.length && i < MAX_DEMO_LOANS; ++i) {
            string memory key = string.concat(".loans.", names[i]);
            uint256 tokenId = vm.parseJsonUint(json, string.concat(key, ".tokenId"));
            string memory role = vm.keyExistsJson(json, string.concat(key, ".role"))
                ? vm.parseJsonString(json, string.concat(key, ".role"))
                : "";
            _printLoan(live, names[i], role, tokenId);
        }
    }

    function _printLoan(Live memory live, string memory name, string memory role, uint256 tokenId) internal view {
        string memory label = string.concat("loan ", name, " (", role, "), position ", vm.toString(tokenId), ": ");
        ILoanManager.Loan memory loan = live.lm.loanOf(tokenId);
        if (loan.state == ILoanManager.LoanState.None) {
            console.log(string.concat(label, "no open loan (closed, or not opened yet)"));
            return;
        }
        string memory health;
        try live.lm.isUnsafe(tokenId) returns (bool unsafe) {
            health = unsafe ? "unsafe at the live price" : "safe at the live price";
        } catch {
            health = "price unavailable";
        }
        console.log(
            string.concat(
                label, "owes ", _amount(live.lm.owedOf(tokenId), 2), " MUSD, due ", _date(loan.maturity), ", ",
                loan.state == ILoanManager.LoanState.Active ? "Active" : "in Auction", ", ",
                live.lm.isOverdue(tokenId) ? "overdue" : "on time", ", ", health
            )
        );
    }

    function _targetMaturity(ICreditMarkets cm) internal view returns (uint64 maturity) {
        maturity = uint64(Math.ceilDiv(block.timestamp + MIN_LEAD_TIME, WEEK) * WEEK);
        if (!cm.isValidMaturity(maturity)) revert MaturityNotOpen(maturity);
    }

    /// @dev Lowest rate among the newest MAX_OFFERS_READ offers that are for exactly `maturity` and still hold at
    ///      least `minLoan`; the earlier id wins a tie.
    function _cheapestOffer(Live memory live, uint64 maturity, uint128 minLoan) internal view returns (Pick memory pick) {
        uint256 next = live.cm.nextOfferId();
        uint256 first = next > MAX_OFFERS_READ ? next - MAX_OFFERS_READ : 1;
        for (uint256 id = first; id < next; ++id) {
            ICreditMarkets.Offer memory o = _offerOf(live, id);
            if (o.maker == address(0) || o.maturity != maturity || o.remaining < minLoan) continue;
            if (pick.offerId == 0 || o.aprBps < pick.aprBps) {
                pick = Pick({offerId: id, aprBps: o.aprBps, remaining: o.remaining, parked: o.parked});
            }
        }
        if (pick.offerId == 0) {
            console.log(
                string.concat(
                    "No open offer for ", _date(maturity), " has the ", _amount(minLoan, 2),
                    " MUSD minimum loan left. A lender must post one before this proof can borrow."
                )
            );
            revert NoUsableOffer(maturity, minLoan);
        }
    }

    function _requireBorrowable(Live memory live, uint256 price, uint256 principal, uint256 face) internal view {
        if (live.lm.borrowsPaused()) revert BorrowsArePaused();
        if (live.borrower.balance < MIN_BORROWER_BTC) revert BorrowerUnderfunded(live.borrower.balance, MIN_BORROWER_BTC);
        uint256 maxFace = Math.mulDiv(Math.mulDiv(LOCK_BTC, price, PRICE_SCALE), live.lm.maxLtvBps(), BPS);
        if (face > maxFace) revert LoanTooLargeForCollateral(face, maxFace);
        uint256 interest = face - principal;
        uint256 held = live.musd.balanceOf(live.borrower);
        if (held < interest) {
            console.log(
                string.concat(
                    "BORROWER holds ", _amount(held, 4), " MUSD but repaying needs ", _amount(interest, 4),
                    " MUSD of interest on top of the loan. Send it a little MUSD and run again. Nothing was sent."
                )
            );
            revert NotEnoughMusdForInterest(held, interest);
        }
    }

    function _borrowedIn(Live memory live, uint256 tokenId, uint256 blockNumber) internal view returns (Borrow memory b) {
        bytes32[] memory topics = new bytes32[](2);
        (topics[0], topics[1]) = (ILoanManager.Borrowed.selector, bytes32(tokenId));
        VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(blockNumber, blockNumber, address(live.lm), topics);
        if (logs.length != 1 || address(uint160(uint256(logs[0].topics[2]))) != live.borrower) {
            revert BorrowNotFound(tokenId, blockNumber);
        }
        b.maturity = uint64(uint256(logs[0].topics[3]));
        (b.principal, b.face) = abi.decode(logs[0].data, (uint256, uint256));
        b.txHash = logs[0].transactionHash;
    }

    function _checkMusdArrived(Live memory live, uint256 borrowBlock, Borrow memory b) internal view {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = IERC20.Transfer.selector;
        topics[1] = bytes32(uint256(uint160(address(live.cm))));
        topics[2] = bytes32(uint256(uint160(live.borrower)));
        VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(borrowBlock, borrowBlock, address(live.musd), topics);
        uint256 arrived;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].transactionHash == b.txHash) arrived += abi.decode(logs[i].data, (uint256));
        }
        _check(
            arrived == b.principal && b.principal != 0,
            string.concat(
                "MUSD arrived: ", _amount(arrived, 2), " MUSD moved from CreditMarkets to the borrower in the borrow transaction (loan principal ",
                _amount(b.principal, 2), ")"
            )
        );
    }

    function _checkCustody(Live memory live, uint256 tokenId, Borrow memory b) internal view {
        ILoanManager.Loan memory loan = live.lm.loanOf(tokenId);
        bool ok = live.veBTC.ownerOf(tokenId) == address(live.lm) && _positionBorrower(live, tokenId) == live.borrower
            && loan.state == ILoanManager.LoanState.Active && loan.face == b.face && loan.maturity == b.maturity;
        _check(
            ok,
            string.concat(
                "LoanManager holds position ", vm.toString(tokenId), " for the borrower, loan Active, ", _amount(b.face, 4),
                " MUSD due ", _date(b.maturity)
            )
        );
    }

    /// @dev Three eth_calls answered by the node at one block, so the value and the price are from the same moment.
    function _checkCollateralValue(Live memory live, uint256 tokenId) internal {
        string memory at = _hexQuantity(block.number);
        (uint256 btcAmount, uint256 usdValue) =
            abi.decode(_ethCall(address(live.lm), abi.encodeCall(ILoanManager.collateralValue, (tokenId)), at), (uint256, uint256));
        (uint256 locked,,) =
            abi.decode(_ethCall(address(live.lm), abi.encodeCall(ILoanManager.lockOf, (tokenId)), at), (uint256, uint256, bool));
        uint256 price = abi.decode(_ethCall(live.priceFeed, abi.encodeCall(IPriceFeed.fetchPrice, ()), at), (uint256));
        bool ok = btcAmount == LOCK_BTC && locked == LOCK_BTC && usdValue == Math.mulDiv(locked, price, PRICE_SCALE);
        _check(
            ok,
            string.concat(
                "collateralValue matches the lock times the oracle: ", _amount(locked, 4), " BTC x ", _amount(price, 2),
                " = ", _amount(usdValue, 2), " MUSD"
            )
        );
    }

    function _attackWithdraw(Live memory live, uint256 tokenId, address stranger) internal {
        bytes memory expected = abi.encodeWithSelector(ILoanManager.NotBorrower.selector, tokenId);
        vm.prank(stranger);
        try live.lm.withdrawCollateral(tokenId) {
            _check(false, "a stranger's withdrawCollateral went through");
        } catch (bytes memory reason) {
            _check(
                keccak256(reason) == keccak256(expected),
                string.concat("a stranger's withdrawCollateral is refused: ", _errorName(reason))
            );
        }
    }

    function _attackStartAuction(Live memory live, uint256 tokenId, address stranger) internal {
        if (live.lm.isOverdue(tokenId) || live.lm.isUnsafe(tokenId)) {
            _check(false, "startAuction attack not run: the loan is not healthy and on time at the live price");
            return;
        }
        bytes memory expected = abi.encodeWithSelector(ILoanManager.NotLiquidatable.selector, tokenId);
        vm.prank(stranger);
        try live.lm.startAuction(tokenId) {
            _check(false, "startAuction on a healthy, on-time loan went through");
        } catch (bytes memory reason) {
            _check(
                keccak256(reason) == keccak256(expected),
                string.concat("startAuction on a healthy, on-time loan is refused: ", _errorName(reason))
            );
        }
    }

    function _attackSettle(Live memory live, uint256 tokenId, address stranger) internal {
        bytes memory expected = abi.encodeWithSelector(ILoanManager.NoAuction.selector, tokenId);
        vm.prank(stranger);
        try live.lm.settle(tokenId) {
            _check(false, "settle on a healthy, on-time loan went through");
        } catch (bytes memory reason) {
            _check(
                keccak256(reason) == keccak256(expected),
                string.concat("settle on a healthy, on-time loan is refused: ", _errorName(reason))
            );
        }
    }

    function _checkRepaid(Live memory live, uint256 tokenId, uint256 repayBlock, uint256 face) internal view {
        bytes32[] memory topics = new bytes32[](3);
        topics[0] = ILoanManager.Repaid.selector;
        topics[1] = bytes32(tokenId);
        topics[2] = bytes32(uint256(uint160(live.borrower)));
        VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(repayBlock, repayBlock, address(live.lm), topics);
        uint256 paid;
        uint256 owedAfter = type(uint256).max;
        if (logs.length == 1) (paid, owedAfter) = abi.decode(logs[0].data, (uint256, uint256));
        bool ok = paid == face && owedAfter == 0 && live.lm.loanOf(tokenId).state == ILoanManager.LoanState.None
            && live.lm.owedOf(tokenId) == 0;
        _check(ok, string.concat("repaid in full: ", _amount(paid, 4), " MUSD paid, nothing left owed, loan closed"));
    }

    function _checkReturned(Live memory live, uint256 tokenId) internal view {
        bool ok = live.veBTC.ownerOf(tokenId) == live.borrower && _positionBorrower(live, tokenId) == address(0);
        _check(ok, string.concat("position ", vm.toString(tokenId), " is back with the borrower and LoanManager keeps no record of it"));
    }

    /// @dev W1. The Filled event only names the offer taken; the fall in parkedPrincipal, the cut in the offer and the
    ///      borrower's MUSD rise are all state read from the node, so they are measured rather than reported. isInVault
    ///      is the test fill itself uses to decide whether to call the vault, so a parked offer whose era was pulled
    ///      out is skipped like a plain one rather than failed.
    function _checkParkedFill(Live memory live, uint256 borrowBlock, Borrow memory b) internal {
        VaultFill memory f = _filledIn(live, borrowBlock, b.txHash);
        if (f.fills != 1) {
            _check(false, string.concat("W1 the borrow transaction filled ", vm.toString(f.fills), " offers, not exactly one"));
            return;
        }
        string memory before = _hexQuantity(borrowBlock - 1);
        string memory at = _hexQuantity(borrowBlock);
        string memory name = string.concat("offer ", vm.toString(f.offerId));
        ICreditMarkets.Offer memory o = _offerAt(live, f.offerId, before);
        if (!o.parked) {
            _skip("W1", string.concat(name, ", the cheapest for ", _date(b.maturity), ", is plain, so its MUSD never sat in the sMUSD vault"));
            return;
        }
        if (!abi.decode(_ethCall(address(live.cm), abi.encodeCall(ICreditMarkets.isInVault, (f.offerId)), before), (bool))) {
            _skip("W1", string.concat(name, " is parked, but its parking era was pulled out, so its MUSD was back in CreditMarkets"));
            return;
        }
        _measureVaultFill(live, f, o.remaining, before, at);
        _reportVaultFill(f, name, b.principal);
    }

    function _measureVaultFill(
        Live memory live,
        VaultFill memory f,
        uint256 remainingBefore,
        string memory before,
        string memory at
    ) internal {
        uint256 remainingAfter = _offerAt(live, f.offerId, at).remaining;
        f.taken = remainingBefore > remainingAfter ? remainingBefore - remainingAfter : 0;
        bytes memory parkedCall = abi.encodeCall(ICreditMarkets.parkedPrincipal, ());
        f.parkedBefore = abi.decode(_ethCall(address(live.cm), parkedCall, before), (uint256));
        f.parkedAfter = abi.decode(_ethCall(address(live.cm), parkedCall, at), (uint256));
        bytes memory musdCall = abi.encodeCall(IERC20.balanceOf, (live.borrower));
        uint256 musdBefore = abi.decode(_ethCall(address(live.musd), musdCall, before), (uint256));
        uint256 musdAfter = abi.decode(_ethCall(address(live.musd), musdCall, at), (uint256));
        f.musdRise = musdAfter > musdBefore ? musdAfter - musdBefore : 0;
    }

    function _reportVaultFill(VaultFill memory f, string memory name, uint256 principal) internal pure {
        bool ok = f.taken != 0 && f.taken == f.filled && f.taken == principal && f.parkedBefore == f.parkedAfter + f.taken
            && f.musdRise == principal;
        string memory vault = string.concat(
            "W1 the loan came out of ", name, ", parked in Mezo's sMUSD vault: parkedPrincipal fell from ",
            _amount(f.parkedBefore, 2), " to ", _amount(f.parkedAfter, 2), " MUSD, by the ", _amount(f.taken, 2)
        );
        _check(
            ok,
            string.concat(
                vault, " taken from the offer, and the borrower's MUSD rose by ", _amount(f.musdRise, 2),
                " (loan principal ", _amount(principal, 2), ")"
            )
        );
    }

    function _filledIn(Live memory live, uint256 borrowBlock, bytes32 txHash) internal view returns (VaultFill memory f) {
        bytes32[] memory topics = new bytes32[](1);
        topics[0] = ICreditMarkets.Filled.selector;
        VmSafe.EthGetLogs[] memory logs = vm.eth_getLogs(borrowBlock, borrowBlock, address(live.cm), topics);
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].transactionHash != txHash) continue;
            ++f.fills;
            f.offerId = uint256(logs[i].topics[1]);
            (f.filled,) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }

    /// @dev Wave 2 only: the five-field shape.
    function _offerAt(Live memory live, uint256 offerId, string memory blockTag)
        internal
        returns (ICreditMarkets.Offer memory)
    {
        return abi.decode(
            _ethCall(address(live.cm), abi.encodeCall(ICreditMarkets.offerOf, (offerId)), blockTag), (ICreditMarkets.Offer)
        );
    }

    function _attackSetOperator(Live memory live, uint256 tokenId, address stranger) internal {
        bytes memory expected = abi.encodeWithSelector(ILoanManager.NotBorrower.selector, tokenId);
        vm.prank(stranger);
        try live.lm.setRewardOperator(tokenId, stranger) {
            _check(false, "W2 a stranger's setRewardOperator naming itself went through");
        } catch (bytes memory reason) {
            _check(
                keccak256(reason) == keccak256(expected),
                string.concat("W2 a stranger's setRewardOperator naming itself is refused, simulated and never sent: ", _errorName(reason))
            );
        }
    }

    function _checkOperatorNamed(Live memory live, uint256 tokenId) internal view {
        ILoanManager.Position memory p = live.lm.positionOf(tokenId);
        _check(
            p.borrower == live.borrower && p.rewardOperator == live.payDown,
            string.concat(
                "W3 the borrower named PayDown ", vm.toString(live.payDown), " reward operator of position ",
                vm.toString(tokenId), " and positionOf reads it back"
            )
        );
    }

    function _checkRecordDeleted(Live memory live, uint256 tokenId) internal view {
        ILoanManager.Position memory p = live.lm.positionOf(tokenId);
        _check(
            p.borrower == address(0) && p.rewardOperator == address(0),
            string.concat(
                "W4 position ", vm.toString(tokenId), "'s record is deleted with it: positionOf reads borrower zero and reward operator zero"
            )
        );
    }

    function _check(bool ok, string memory what) internal pure {
        console.log(string.concat(ok ? "PASS " : "FAIL ", what));
    }

    function _skip(string memory label, string memory why) internal pure {
        console.log(string.concat("SKIP ", label, " ", why));
    }

    function _errorName(bytes memory reason) internal pure returns (string memory) {
        if (reason.length < 4) return "reverted with no reason";
        bytes4 selector = bytes4(reason);
        if (selector == ILoanManager.NotBorrower.selector) return "NotBorrower";
        if (selector == ILoanManager.NotLiquidatable.selector) return "NotLiquidatable";
        if (selector == ILoanManager.NoAuction.selector) return "NoAuction";
        if (selector == ILoanManager.FloorTimeNotReached.selector) return "FloorTimeNotReached";
        if (selector == ILoanManager.StillSafe.selector) return "StillSafe";
        return string.concat("error ", vm.toString(abi.encodePacked(selector)));
    }

    /// @dev Asks the node itself, so the answer comes from the real precompiles rather than the local stand-ins.
    function _ethCall(address to, bytes memory data, string memory blockTag) internal returns (bytes memory) {
        string memory params =
            string.concat('[{"to":"', vm.toString(to), '","data":"', vm.toString(data), '"},"', blockTag, '"]');
        return vm.rpc("eth_call", params);
    }

    function _hexQuantity(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0x0";
        bytes16 digits = "0123456789abcdef";
        uint256 len;
        for (uint256 v = value; v != 0; v >>= 4) {
            ++len;
        }
        bytes memory out = new bytes(len + 2);
        (out[0], out[1]) = ("0", "x");
        for (uint256 i = len + 1; i > 1; --i) {
            out[i] = digits[value & 0xf];
            value >>= 4;
        }
        return string(out);
    }

    function _amount(uint256 value, uint256 shown) internal pure returns (string memory) {
        string memory frac = vm.toString((value % 1e18) / 10 ** (18 - shown));
        while (bytes(frac).length < shown) {
            frac = string.concat("0", frac);
        }
        return string.concat(vm.toString(value / 1e18), ".", frac);
    }

    function _pct(uint16 bps) internal pure returns (string memory) {
        return string.concat(vm.toString(bps / 100), ".", _two(bps % 100), "%");
    }

    function _two(uint256 n) internal pure returns (string memory) {
        return n < 10 ? string.concat("0", vm.toString(n)) : vm.toString(n);
    }

    /// @dev Civil date from a Unix time, after Howard Hinnant's days-from-civil inverse.
    function _date(uint256 ts) internal pure returns (string memory) {
        uint256 z = ts / 1 days + 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        uint256 day = doy - (153 * mp + 2) / 5 + 1;
        uint256 month = mp < 10 ? mp + 3 : mp - 9;
        uint256 year = yoe + era * 400 + (month <= 2 ? 1 : 0);
        return string.concat(vm.toString(year), "-", _two(month), "-", _two(day));
    }

    function _dateTime(uint256 ts) internal pure returns (string memory) {
        return string.concat(_date(ts), " ", _two((ts % 1 days) / 1 hours), ":", _two((ts % 1 hours) / 1 minutes), " UTC");
    }
}
