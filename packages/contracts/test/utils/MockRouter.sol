// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IMezoRouter} from "../../src/interfaces/IMezoRouter.sol";

/// @notice Stand-in for Mezo's pool Router with the live call shape (Route[] hops, amountOutMin checked against
/// its own quote, Expired, InvalidPath). Each hop pays at a settable rate per token pair, output = input x rate /
/// 1e18, from MUSD the test mints to it. It pulls the input from the caller, touches every middle-hop token with
/// a zero transfer the way Mezo's pools move tokens pool to pool, so a hostile token on a route gets to run, and
/// can be told to pay `shortBps` less than the amount it returns, the way a sandwich or a fee-on-transfer leg
/// would leave the caller short. It records the last swap for the tests to read.
contract MockRouter {
    address public immutable defaultFactory;
    mapping(address from => mapping(address to => uint256)) public rate;
    uint256 public shortBps;
    uint256 public swaps;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMin;
    uint256 public lastHops;
    IMezoRouter.Route public lastFirstHop;

    error InsufficientOutputAmount();
    error Expired();
    error InvalidPath();

    constructor(address defaultFactory_) {
        defaultFactory = defaultFactory_;
    }

    function setRate(address from, address to, uint256 rate_) external {
        rate[from][to] = rate_;
    }

    function setShortBps(uint256 bps) external {
        shortBps = bps;
    }

    function getAmountsOut(uint256 amountIn, IMezoRouter.Route[] memory routes)
        public
        view
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        for (uint256 i; i < routes.length; ++i) {
            amounts[i + 1] = amounts[i] * rate[routes[i].from][routes[i].to] / 1e18;
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        IMezoRouter.Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts) {
        if (deadline < block.timestamp) revert Expired();
        uint256 hops = routes.length;
        if (hops == 0) revert InvalidPath();
        amounts = getAmountsOut(amountIn, routes);
        uint256 out = amounts[hops];
        if (out < amountOutMin) revert InsufficientOutputAmount();
        ++swaps;
        lastAmountIn = amountIn;
        lastAmountOutMin = amountOutMin;
        lastHops = hops;
        lastFirstHop = routes[0];

        IERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);
        for (uint256 i = 1; i < hops; ++i) {
            IERC20(routes[i].from).transfer(address(this), 0);
        }
        IERC20(routes[hops - 1].to).transfer(to, out - out * shortBps / 10_000);
    }
}

/// @notice An ERC-20 that, once armed, makes one call to `target` the next time `trigger` sends it, and passes on
/// any revert, so a test can put attacker code inside a swap route.
contract CallbackToken is ERC20 {
    address public trigger;
    address public target;
    bytes public callData;

    constructor() ERC20("Callback", "CB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address trigger_, address target_, bytes calldata data) external {
        trigger = trigger_;
        target = target_;
        callData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        address callee = target;
        if (callee == address(0) || from != trigger) return;
        target = address(0);
        (bool ok, bytes memory reason) = callee.call(callData);
        if (!ok) {
            assembly {
                revert(add(reason, 32), mload(reason))
            }
        }
    }
}
