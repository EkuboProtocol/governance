// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

abstract contract L1L2OwnerProxy is Ownable {
    error InvalidTarget();
    error InsufficientBalance();
    error CallFailed(bytes data);

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert NewOwnerIsZeroAddress();
        _initializeOwner(initialOwner);
    }

    function execute(address target, uint256 value, bytes calldata data) external onlyOwner returns (bytes memory) {
        if (target == address(0)) revert InvalidTarget();
        if (address(this).balance < value) revert InsufficientBalance();

        (bool success, bytes memory result) = target.call{value: value}(data);
        if (!success) revert CallFailed(result);
        return result;
    }

    function _checkOwner() internal view override {
        if (msg.sender != owner() && !_isL1Owner()) revert Unauthorized();
    }

    function _isL1Owner() internal view virtual returns (bool);
}
