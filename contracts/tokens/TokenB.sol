// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title TokenA
 * @dev A simple ERC20 token implementation with:
 * - Fixed supply of 1,000,000 tokens
 * - No decimal places (integer amounts only)
 * - Basic ERC20 functionality
 * @author Francisco López G.
 */
contract TokenB is ERC20 {
    // ==============================================
    //              CONSTRUCTOR
    // ==============================================

    /**
     * @dev Initializes the TokenB contract
     * - Sets token name to "TokenB"
     * - Sets token symbol to "TKB"
     * - Mints initial supply of 1,000,000 tokens to deployer
     */
    constructor() ERC20("TokenB", "TKB") {
        // Mint initial supply to contract deployer
        _mint(msg.sender, 1000000);
    }

    // ==============================================
    //              PUBLIC FUNCTIONS
    // ==============================================

    /**
     * @notice Returns the number of decimals used by the token
     * @dev Overrides the standard ERC20 decimals function
     * @return uint8 Always returns 0 (token uses integer amounts only)
     */
    function decimals() public pure override returns (uint8) {
        return 0;
    }
}
