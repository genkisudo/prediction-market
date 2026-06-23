// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-165 interface used by the CRE KeystoneForwarder to
///         detect that a target contract is a valid report receiver.
interface IERC165 {
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
}
