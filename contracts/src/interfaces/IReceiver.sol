// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC165} from "./IERC165.sol";

/// @notice Interface a contract must implement to receive CRE workflow reports
///         forwarded by the Chainlink KeystoneForwarder.
/// @dev    See https://docs.chain.link/cre/guides/workflow/using-evm-client/onchain-write/building-consumer-contracts
interface IReceiver is IERC165 {
    /// @param metadata Workflow ID, DON ID and execution metadata appended by the forwarder.
    /// @param report   ABI-encoded payload produced by `runtime.report()` in the workflow.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
