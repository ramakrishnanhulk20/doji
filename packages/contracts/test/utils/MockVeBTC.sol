// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {MockBTC} from "./MockBTC.sol";

/// @notice Stand-in for Mezo's veBTC. locked() returns 3 words (testnet shape) or 4 (mainnet shape), and
/// ownerOf returns the zero address for a missing id, as Mezo mainnet does. withdraw, unlockPermanent,
/// createLockFor, increaseUnlockTime and depositFor follow the checks of the live Escrow library, and BTC moves
/// in a mock BTC ERC-20 as the live one moves through the BTC ERC-20 view. createLockFor mints without a
/// receiver hook, as the live one does.
contract MockVeBTC is ERC721 {
    struct LockData {
        int128 amount;
        uint256 end;
        bool isPermanent;
    }

    uint256 internal constant WEEK = 604_800;
    uint256 public constant MAX_LOCK_TIME = 28 days;

    uint256 public layoutWords;
    bool public transfersIgnored;
    MockBTC public immutable btc;
    uint256 public nextTokenId = 50_000;
    uint256 public lockPullBps = 10_000;
    address public mintRecipientOverride;
    uint8 public mintEscrowType;

    mapping(uint256 tokenId => LockData) private _locks;
    mapping(uint256 tokenId => uint8) public escrowType;
    mapping(uint256 tokenId => address) public grantManager;
    mapping(uint256 tokenId => bool) internal _votedByHand;
    mapping(uint256 tokenId => mapping(address voter => bool)) public votedBy;
    mapping(uint256 tokenId => uint256) public voterCount;
    mapping(uint256 tokenId => bool) public hasPayoutOverride;
    mapping(uint256 tokenId => uint256) public payoutOverride;

    error NotApprovedOrOwner();
    error AlreadyVoted();
    error NotNormalNFT();
    error PermanentLock();
    error NotPermanentLock();
    error LockNotExpired();
    error ZeroAmount();
    error LockDurationNotInFuture();
    error LockDurationTooLong();
    error LockExpired();

    constructor(uint256 layoutWords_, MockBTC btc_) ERC721("Mock veBTC", "veBTC") {
        layoutWords = layoutWords_;
        btc = btc_;
    }

    function mint(address to, uint256 tokenId, int128 amount, uint256 end, bool isPermanent) external {
        _mint(to, tokenId);
        _locks[tokenId] = LockData(amount, end, isPermanent);
    }

    function setLock(uint256 tokenId, int128 amount, uint256 end, bool isPermanent) external {
        _locks[tokenId] = LockData(amount, end, isPermanent);
    }

    function setLayoutWords(uint256 words) external {
        layoutWords = words;
    }

    function setEscrowType(uint256 tokenId, uint8 kind) external {
        escrowType[tokenId] = kind;
    }

    function setGrantManager(uint256 tokenId, address manager) external {
        grantManager[tokenId] = manager;
    }

    /// @dev Marks a position voted by hand, standing in for a vote on a voter no test models.
    function setVoted(uint256 tokenId, bool isVoted) external {
        _votedByHand[tokenId] = isVoted;
    }

    /// @dev Mirrors the live votedVoters list: each voter adds or removes itself, and the position counts as voted
    ///      while any voter holds a vote. Open to any caller here; on Mezo only registered voters may call it.
    function voting(uint256 tokenId, bool isVoted) external {
        if (votedBy[tokenId][msg.sender] == isVoted) return;
        votedBy[tokenId][msg.sender] = isVoted;
        if (isVoted) ++voterCount[tokenId];
        else --voterCount[tokenId];
    }

    function voted(uint256 tokenId) public view returns (bool) {
        return _votedByHand[tokenId] || voterCount[tokenId] != 0;
    }

    /// @dev Makes withdraw pay `amount` instead of the locked amount, to prove settle measures what arrives.
    function setWithdrawPayout(uint256 tokenId, uint256 amount) external {
        hasPayoutOverride[tokenId] = true;
        payoutOverride[tokenId] = amount;
    }

    /// @dev Makes transferFrom silently do nothing, to prove LoanManager checks custody after pulling.
    function setTransfersIgnored(bool ignored) external {
        transfersIgnored = ignored;
    }

    /// @dev Moves a token without approval, standing in for a veBTC flaw that takes custody away.
    function forceTransfer(address from, address to, uint256 tokenId) external {
        _transfer(from, to, tokenId);
    }

    /// @dev Makes createLockFor pull only `bps` of the BTC it was asked to lock, to prove LoanManager leaves no
    ///      allowance behind whatever veBTC spends.
    function setLockPullBps(uint256 bps) external {
        lockPullBps = bps;
    }

    /// @dev Makes createLockFor mint to `recipient` instead of the address asked for, to prove LoanManager
    ///      records a minted id only once it owns it.
    function setMintRecipientOverride(address recipient) external {
        mintRecipientOverride = recipient;
    }

    /// @dev Escrow type createLockFor gives new positions, to prove LoanManager runs the C2 test on a mint.
    function setMintEscrowType(uint8 kind) external {
        mintEscrowType = kind;
    }

    function lockData(uint256 tokenId) external view returns (int128 amount, uint256 end, bool isPermanent) {
        LockData memory lock = _locks[tokenId];
        return (lock.amount, lock.end, lock.isPermanent);
    }

    function createLockFor(uint256 value, uint256 lockDuration, address to) external returns (uint256 tokenId) {
        if (value == 0) revert ZeroAmount();
        uint256 end = ((block.timestamp + lockDuration) / WEEK) * WEEK;
        if (end <= block.timestamp) revert LockDurationNotInFuture();
        if (end > block.timestamp + MAX_LOCK_TIME) revert LockDurationTooLong();
        btc.transferFrom(msg.sender, address(this), value * lockPullBps / 10_000);

        tokenId = nextTokenId++;
        _mint(mintRecipientOverride == address(0) ? to : mintRecipientOverride, tokenId);
        _locks[tokenId] = LockData(int128(int256(value)), end, false);
        escrowType[tokenId] = mintEscrowType;
    }

    function increaseUnlockTime(uint256 tokenId, uint256 lockDuration) external {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (escrowType[tokenId] != 0) revert NotNormalNFT();
        LockData storage lock = _locks[tokenId];
        if (lock.isPermanent) revert PermanentLock();
        if (lock.end <= block.timestamp) revert LockExpired();
        uint256 end = ((block.timestamp + lockDuration) / WEEK) * WEEK;
        if (end <= lock.end) revert LockDurationNotInFuture();
        if (end > block.timestamp + MAX_LOCK_TIME) revert LockDurationTooLong();
        lock.end = end;
    }

    /// @dev Open to anyone on a normal, unexpired or permanent position, as the live one is.
    function depositFor(uint256 tokenId, uint256 value) external {
        if (value == 0) revert ZeroAmount();
        LockData storage lock = _locks[tokenId];
        if (!lock.isPermanent && lock.end <= block.timestamp) revert LockExpired();
        btc.transferFrom(msg.sender, address(this), value);
        lock.amount += int128(int256(value));
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        return _isAuthorized(_ownerOf(tokenId), spender, tokenId);
    }

    function ownerOf(uint256 tokenId) public view override returns (address) {
        return _ownerOf(tokenId);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (transfersIgnored) return;
        super.transferFrom(from, to, tokenId);
    }

    function withdraw(uint256 tokenId) external {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (voted(tokenId)) revert AlreadyVoted();
        if (escrowType[tokenId] != 0) revert NotNormalNFT();
        LockData memory lock = _locks[tokenId];
        if (lock.isPermanent) revert PermanentLock();
        if (block.timestamp < lock.end) revert LockNotExpired();
        uint256 value = hasPayoutOverride[tokenId] ? payoutOverride[tokenId] : uint256(int256(lock.amount));

        _burn(tokenId);
        delete _locks[tokenId];
        btc.mint(msg.sender, value);
    }

    function unlockPermanent(uint256 tokenId) external {
        if (!_isAuthorized(_ownerOf(tokenId), msg.sender, tokenId)) revert NotApprovedOrOwner();
        if (escrowType[tokenId] != 0) revert NotNormalNFT();
        if (voted(tokenId)) revert AlreadyVoted();
        LockData storage lock = _locks[tokenId];
        if (!lock.isPermanent) revert NotPermanentLock();
        lock.isPermanent = false;
        lock.end = ((block.timestamp + MAX_LOCK_TIME) / WEEK) * WEEK;
    }

    function locked(uint256 tokenId) external view {
        LockData memory lock = _locks[tokenId];
        bytes memory out = layoutWords == 4
            ? abi.encode(lock.amount, lock.end, lock.isPermanent, uint256(1e18))
            : abi.encode(lock.amount, lock.end, lock.isPermanent);
        assembly {
            return(add(out, 32), mload(out))
        }
    }
}
