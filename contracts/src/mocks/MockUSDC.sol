// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice A 6-decimal mock USDC for local and testnet deployments / demos.
/// @dev Anyone can mint on testnet via the faucet; do NOT deploy this to mainnet.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USD Coin", "USDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Open faucet for demos: mint yourself test USDC.
    function faucet(uint256 amount) external {
        _mint(msg.sender, amount);
    }

    /// @notice Mint to an arbitrary address (demo seeding).
    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
