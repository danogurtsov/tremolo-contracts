// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @notice Tokens that break the ERC-20 assumptions this protocol would otherwise inherit.
/// @dev SECURITY.md used to *declare* which tokens are unsupported. A declaration nobody tests
///      is a wish. These exist so each claim is backed by a test that fails if the claim stops
///      being true.

/// @notice USDT-style: no return value at all on transfer and approve.
/// @dev The most likely collateral in production and the most common integration failure. A
///      naive `IERC20(t).transfer(...)` reverts against this token, because the compiler expects
///      32 bytes of returndata and receives none. SafeTransferLib is what makes it work.
contract NoReturnToken {
    string public name = "Tether-style";
    string public symbol = "USDT";
    uint8 public constant decimals = 6;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    // Deliberately no `returns (bool)`.
    function transfer(address to, uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "balance");
        unchecked {
            balanceOf[msg.sender] -= amount;
        }
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        require(balanceOf[from] >= amount, "balance");
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allowance");
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        unchecked {
            balanceOf[from] -= amount;
        }
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }
}

/// @notice Takes a cut of every transfer.
/// @dev Fatal to any protocol that assumes the amount it asked for is the amount that arrived.
///      Here the market would credit a subscription in full while holding less collateral than
///      the position requires — an under-collateralised series, which is the one thing the
///      design promises cannot exist.
contract FeeOnTransferToken is MockERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) MockERC20("Fee On Transfer", "FOT", 18) {
        feeBps = feeBps_;
    }

    function _fee(uint256 amount) internal view returns (uint256) {
        return amount * feeBps / 10_000;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 fee = _fee(amount);
        super.transfer(address(this), fee);
        return super.transfer(to, amount - fee);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        uint256 fee = _fee(amount);
        super.transferFrom(from, address(this), fee);
        return super.transferFrom(from, to, amount - fee);
    }
}

/// @notice Calls back into the market on every transfer.
/// @dev ERC-777 and its descendants hand control to the recipient mid-transfer. The market
///      holds `nonReentrant`, but a modifier that is never exercised is an assumption. This
///      token turns it into a tested property.
contract ReentrantToken is MockERC20 {
    address public target;
    bytes public payload;
    bool internal entered;

    constructor() MockERC20("Reentrant", "RENT", 18) {}

    function setAttack(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
    }

    function _reenter() internal {
        if (target == address(0) || entered) return;
        entered = true;
        (bool ok, bytes memory ret) = target.call(payload);
        entered = false;
        // Bubble up so the test sees whether the guard held, rather than swallowing it.
        if (!ok) {
            assembly {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        _reenter();
        return ok;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool ok = super.transferFrom(from, to, amount);
        _reenter();
        return ok;
    }
}

/// @notice Reverts on any zero-value transfer, as a handful of real tokens do.
contract RevertOnZeroToken is MockERC20 {
    constructor() MockERC20("Revert On Zero", "ROZ", 18) {}

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(amount > 0, "zero transfer");
        return super.transfer(to, amount);
    }
}
