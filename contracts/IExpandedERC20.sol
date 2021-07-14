// SPDX-License-Identifier: MIT
pragma solidity ^0.6.0;

/**
 * @dev Interface of the ERC20 standard as defined in the EIP.
 */
interface IExpandedERC20 {
    function mint(address account, uint256 amount) external;
    
    function burn(address account, uint256 amount) external;

    function burnFrom(address account, uint256 amount) external;
}