// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

interface IStarknetMessaging {
    function sendMessageToL2(uint256 toAddress, uint256 selector, uint256[] calldata payload) external payable returns (bytes32, uint256);
}

contract StarknetStakingProxy {
    error InvalidTarget();
    error InsufficientBalance();
    error InvalidNonce(uint64 current, uint64 nonce);
    error CallFailed(bytes data);
    error Unauthorized();

    IStarknetMessaging public immutable l2MessageBridge;
    uint256 public immutable l2StakingProxy;
    
    // L1 handler selector for the L2 contract
    // This should be computed as starknet_keccak("handle_l1_message_entry".as_bytes())
    // TODO: Replace with actual computed selector from deployed L2 contract
    uint256 public constant L1_HANDLER_SELECTOR = 0x02d757788a8d8d6f21d1cd40bce38a8222d70654214e96ff95d8086e684fbee5;
    
    address public owner;
    uint64 public currentNonce;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event StakeMessageSent(address indexed delegate, uint128 amount, uint64 nonce);
    event WithdrawMessageSent(address indexed delegate, address indexed recipient, uint128 amount, uint64 nonce);
    event EmergencyTransferMessageSent(address indexed token, address indexed recipient, uint256 amount, uint64 nonce);
    event ArbitraryCallsMessageSent(uint256 callsCount, uint64 nonce);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(IStarknetMessaging _l2MessageBridge, uint256 _l2StakingProxy, address _owner) {
        l2MessageBridge = _l2MessageBridge;
        l2StakingProxy = _l2StakingProxy;
        owner = _owner;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // Stake tokens to a delegate
    function stake(address delegate, uint128 amount) external payable onlyOwner returns (bytes32, uint256) {
        uint64 nonce = currentNonce++;
        
        // Encode StakingOperation::Stake
        uint256[] memory payload = new uint256[](4);
        payload[0] = 0; // StakingOperation::Stake variant
        payload[1] = uint256(uint160(delegate)); // delegate address
        payload[2] = uint256(amount); // amount (low part)
        payload[3] = 0; // amount (high part, always 0 for u128)
        
        (bytes32 messageHash, uint256 messageFee) = l2MessageBridge.sendMessageToL2{value: msg.value}(
            l2StakingProxy,
            L1_HANDLER_SELECTOR,
            payload
        );
        
        emit StakeMessageSent(delegate, amount, nonce);
        return (messageHash, messageFee);
    }

    // Withdraw tokens from a delegate to a recipient
    function withdraw(address delegate, address recipient, uint128 amount) external payable onlyOwner returns (bytes32, uint256) {
        uint64 nonce = currentNonce++;
        
        // Encode StakingOperation::Withdraw
        uint256[] memory payload = new uint256[](5);
        payload[0] = 1; // StakingOperation::Withdraw variant
        payload[1] = uint256(uint160(delegate)); // delegate address
        payload[2] = uint256(uint160(recipient)); // recipient address
        payload[3] = uint256(amount); // amount (low part)
        payload[4] = 0; // amount (high part, always 0 for u128)
        
        (bytes32 messageHash, uint256 messageFee) = l2MessageBridge.sendMessageToL2{value: msg.value}(
            l2StakingProxy,
            L1_HANDLER_SELECTOR,
            payload
        );
        
        emit WithdrawMessageSent(delegate, recipient, amount, nonce);
        return (messageHash, messageFee);
    }

    // Emergency transfer tokens out of the L2 contract
    function emergencyTransfer(address token, address recipient, uint256 amount) external payable onlyOwner returns (bytes32, uint256) {
        uint64 nonce = currentNonce++;
        
        // Encode StakingOperation::EmergencyTransfer
        uint256[] memory payload = new uint256[](6);
        payload[0] = 4; // StakingOperation::EmergencyTransfer variant
        payload[1] = uint256(uint160(token)); // token address
        payload[2] = uint256(uint160(recipient)); // recipient address
        payload[3] = uint256(amount & 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF); // amount low
        payload[4] = uint256(amount >> 128); // amount high
        payload[5] = 0; // padding
        
        (bytes32 messageHash, uint256 messageFee) = l2MessageBridge.sendMessageToL2{value: msg.value}(
            l2StakingProxy,
            L1_HANDLER_SELECTOR,
            payload
        );
        
        emit EmergencyTransferMessageSent(token, recipient, amount, nonce);
        return (messageHash, messageFee);
    }

    // Execute arbitrary calls on L2
    function executeCalls(bytes calldata encodedCalls) external payable onlyOwner returns (bytes32, uint256) {
        uint64 nonce = currentNonce++;
        
        // For arbitrary calls, we need to encode the calls data
        // This is a simplified version - in practice, you'd need to properly encode the Call structs
        uint256 chunkCount = (encodedCalls.length + 30) / 31;
        uint256[] memory payload = new uint256[](3 + chunkCount);
        
        payload[0] = 2; // StakingOperation::ExecuteCalls variant
        payload[1] = encodedCalls.length; // calls data length
        payload[2] = chunkCount; // number of chunks
        
        // Split the calls data into 31-byte chunks
        for (uint256 i = 0; i < chunkCount; i++) {
            assembly ("memory-safe") {
                mstore(add(payload, mul(add(i, 4), 32)), shr(8, calldataload(add(encodedCalls.offset, mul(i, 31)))))
            }
        }
        
        (bytes32 messageHash, uint256 messageFee) = l2MessageBridge.sendMessageToL2{value: msg.value}(
            l2StakingProxy,
            L1_HANDLER_SELECTOR,
            payload
        );
        
        emit ArbitraryCallsMessageSent(chunkCount, nonce);
        return (messageHash, messageFee);
    }

    // Upgrade the L2 contract
    function upgrade(uint256 newClassHash) external payable onlyOwner returns (bytes32, uint256) {
        uint64 nonce = currentNonce++;
        
        // Encode StakingOperation::Upgrade
        uint256[] memory payload = new uint256[](3);
        payload[0] = 3; // StakingOperation::Upgrade variant
        payload[1] = newClassHash; // new class hash (low part)
        payload[2] = 0; // new class hash (high part, typically 0)
        
        (bytes32 messageHash, uint256 messageFee) = l2MessageBridge.sendMessageToL2{value: msg.value}(
            l2StakingProxy,
            L1_HANDLER_SELECTOR,
            payload
        );
        
        return (messageHash, messageFee);
    }

    // Allow contract to receive ETH for message fees
    receive() external payable {}
    
    // Allow owner to withdraw ETH
    function withdrawETH(uint256 amount) external onlyOwner {
        if (address(this).balance < amount) revert InsufficientBalance();
        payable(owner).transfer(amount);
    }
}
