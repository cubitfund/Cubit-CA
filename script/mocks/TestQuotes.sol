// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// Test quotes for Anvil and Sepolia, where USDC, USDT, WBTC and the Ondo stocks do not exist. Anyone can mint them:
// they have no value and must never be deployed on mainnet (TestQuotesDeploy refuses chain 1).

/// @notice An ERC-20 quote with the decimals of a real one: 6 (USDC), 8 (WBTC) or 18 (a tokenized stock).
contract MockQuote is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(string.concat("Test ", symbol_), symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice USDT's shape: `transfer`, `transferFrom` and `approve` return nothing, and a non-zero allowance must be
///         reset to zero before it is changed.
contract MockNoReturnQuote {
    string public constant name = "Test USDT";
    string public constant symbol = "USDT";
    uint8 public constant decimals = 6;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        require(amount == 0 || allowance[msg.sender][spender] == 0, "USDT: reset allowance first");
        allowance[msg.sender][spender] = amount;
    }
}
