// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IReceiver} from "./IReceiver.sol";
import {IERC165} from "./IERC165.sol";

/// @title  ReceiverTemplate
/// @notice Base contract for CRE report consumers. Restricts `onReport` to the
///         configured KeystoneForwarder and advertises IReceiver support via ERC-165.
/// @dev    Mirrors the official Chainlink CRE ReceiverTemplate. Inheritors implement
///         `_processReport`. Pulled into the repo because the CRE receiver contracts
///         are not published as an installable package.
abstract contract ReceiverTemplate is IReceiver {
    /// @notice The KeystoneForwarder allowed to deliver reports.
    address public immutable i_forwarder;

    error UnauthorizedForwarder(address caller, address expected);

    constructor(address forwarder) {
        require(forwarder != address(0), "forwarder=0");
        i_forwarder = forwarder;
    }

    modifier onlyForwarder() {
        if (msg.sender != i_forwarder) {
            revert UnauthorizedForwarder(msg.sender, i_forwarder);
        }
        _;
    }

    /// @inheritdoc IReceiver
    function onReport(bytes calldata metadata, bytes calldata report) external override onlyForwarder {
        _processReport(metadata, report);
    }

    /// @notice Implemented by the consumer to act on a verified report.
    function _processReport(bytes calldata metadata, bytes calldata report) internal virtual;

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
