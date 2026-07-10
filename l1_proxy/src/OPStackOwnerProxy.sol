// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";

interface ICrossDomainMessenger {
    function xDomainMessageSender() external view returns (address);
}

contract OPStackOwnerProxy is Ownable {
    address public constant L2_CROSS_DOMAIN_MESSENGER = 0x4200000000000000000000000000000000000007;

    error InvalidTarget();
    error InsufficientBalance();
    error RenounceOwnershipDisabled();
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

    function renounceOwnership() public payable override onlyOwner {
        revert RenounceOwnershipDisabled();
    }

    function _checkOwner() internal view override {
        if (
            msg.sender != L2_CROSS_DOMAIN_MESSENGER
                || ICrossDomainMessenger(L2_CROSS_DOMAIN_MESSENGER).xDomainMessageSender() != owner()
        ) {
            revert Unauthorized();
        }
    }

    receive() external payable {}
}
