// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts ^5.0.0
pragma solidity ^0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title TokenB
 * @dev An ERC20 token implementation with:
 * - Fixed initial supply of 1,000,000 tokens (with 18 decimals)
 * - Standard 18 decimal places (OpenZeppelin default)
 * - Ownable functionality (initial owner only)
 * - No mint capability after deployment
 * @author Francisco López G.
 */
contract TokenB is ERC20, Ownable {
    // ==============================================
    //              STATE VARIABLES
    // ==============================================

    /**
     * @dev Constant for maximum token supply (1 million tokens)
     * @notice 1 token = 10^18 units (standard ERC20 decimals)
     */
    uint256 public constant MAX_SUPPLY = 1_000_000 * 10 ** 18;

    // ==============================================
    //              CONSTRUCTOR
    // ==============================================

    /**
     * @dev Initializes the TokenB contract:
     * - Sets token name to "TokenB"
     * - Sets token symbol to "TKB"
     * - Assigns initial owner
     * - Mints fixed supply to initial owner
     * @param initialOwner Address receiving:
     *   - Contract ownership
     *   - Initial token supply (1,000,000 tokens)
     */
    constructor(
        address initialOwner
    ) ERC20("TokenB", "TKB") Ownable(initialOwner) {
        _mint(initialOwner, MAX_SUPPLY);
    }

    // ==============================================
    //              PUBLIC FUNCTIONS
    // ==============================================

    /**
     * @notice This contract intentionally omits mint functionality
     * @dev Any attempt to mint will fail (no function exists)
     * @dev Ownership remains for potential upgrades/pausing
     */
    // No mint function included -> Supply is fixed forever
}
