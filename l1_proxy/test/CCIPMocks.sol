// SPDX-License-Identifier: UNLICENSED
pragma solidity =0.8.28;

import {Ownable} from "solady/auth/Ownable.sol";
import {Client} from "../vendor/ccip-2.0.0/libraries/Client.sol";
import {IAny2EVMMessageReceiver} from "../vendor/ccip-2.0.0/interfaces/IAny2EVMMessageReceiver.sol";
import {CCIPGovernancePayload} from "../src/CCIPGovernancePayload.sol";
import {CCIPOwnerExecutor} from "../src/CCIPOwnerExecutor.sol";

/// @notice MOCKED CCIP router for unit tests. Source side: quotes a configurable fee and records sends; it keeps any
///         excess msg.value, like Router 1.2. Destination side: `deliver` mirrors OffRamp 2.0 `_isTokenOnlyTransfer`
///         (OffRamp.sol:426): a receiver with no code or without IAny2EVMMessageReceiver is skipped and reported as
///         SUCCESS without any call.
contract MockCCIPRouter {
    uint256 public fee;
    bool public sendReverts;
    bool public feeReverts;
    uint256 public nonce;
    uint256 public received;

    struct Sent {
        uint64 dest;
        bytes receiver;
        bytes data;
        uint256 tokenCount;
        address feeToken;
        bytes extraArgs;
        uint256 value;
    }

    Sent[] internal sent;

    error Cursed();

    function setFee(uint256 f) external {
        fee = f;
    }

    function setSendReverts(bool v) external {
        sendReverts = v;
    }

    function setFeeReverts(bool v) external {
        feeReverts = v;
    }

    function getFee(uint64, Client.EVM2AnyMessage memory) external view returns (uint256) {
        if (feeReverts) revert Cursed();
        return fee;
    }

    function ccipSend(uint64 dest, Client.EVM2AnyMessage calldata m) external payable returns (bytes32 id) {
        if (sendReverts) revert Cursed();
        require(msg.value >= fee, "fee");
        received += msg.value;
        sent.push(Sent(dest, m.receiver, m.data, m.tokenAmounts.length, m.feeToken, m.extraArgs, msg.value));
        id = keccak256(abi.encode("msg", ++nonce));
    }

    function sentCount() external view returns (uint256) {
        return sent.length;
    }

    function lastSent() external view returns (Sent memory) {
        return sent[sent.length - 1];
    }

    /// @dev `skipped` is true when the OffRamp would mark SUCCESS without calling the receiver.
    function deliver(address receiver, Client.Any2EVMMessage calldata m, uint256 gasLimit)
        external
        returns (bool success, bool skipped, bytes memory ret)
    {
        if (receiver.code.length == 0) return (true, true, "");
        (bool ok, bytes memory r) = receiver.staticcall{gas: 30_000}(
            abi.encodeWithSelector(0x01ffc9a7, type(IAny2EVMMessageReceiver).interfaceId)
        );
        if (!ok || r.length < 32 || abi.decode(r, (bool)) == false) return (true, true, "");
        (success, ret) =
            receiver.call{gas: gasLimit}(abi.encodeWithSelector(IAny2EVMMessageReceiver.ccipReceive.selector, m));
    }
}

/// @notice Stand-in for a residual Ekubo peripheral: solady Ownable with an owner-only setter.
contract MockOwnedTarget is Ownable {
    uint256 public x;
    uint256 public calls;
    address public reenterInto;
    bytes public reenterData;
    bool public lastReentryReverted;
    bytes public lastReentryError;

    constructor(address o) {
        _initializeOwner(o);
    }

    function setX(uint256 v) external onlyOwner {
        x = v;
        calls++;
    }

    function fail() external pure {
        revert("target failed");
    }

    function armReentry(address into, bytes calldata data) external {
        reenterInto = into;
        reenterData = data;
    }

    /// @dev Owner-only call that re-enters `reenterInto` and records the outcome; does not bubble it.
    function poke() external onlyOwner {
        calls++;
        (bool ok, bytes memory r) = reenterInto.call(reenterData);
        lastReentryReverted = !ok;
        lastReentryError = r;
    }

    /// @dev Same, but bubbles the reentry failure so the whole batch reverts.
    function pokeStrict() external onlyOwner {
        calls++;
        (bool ok, bytes memory r) = reenterInto.call(reenterData);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(r, 32), mload(r))
            }
        }
    }
}

/// @notice Test-only stand-in for the canceller Safe (any contract address; no real signers).
contract MockCanceller {
    function cancel(CCIPOwnerExecutor e, bytes32[] calldata hashes) external {
        e.cancel(hashes);
    }

    function tryExecute(CCIPOwnerExecutor e, bytes calldata payload) external {
        e.execute(payload);
    }
}

/// @notice A contract with code but no ERC-165 receiver interface (silent-success case).
contract NoInterface {
    uint256 public touched;

    function ccipReceive(Client.Any2EVMMessage calldata) external {
        touched++;
    }
}

library PayloadLib {
    function one(address target, bytes memory data) internal pure returns (CCIPGovernancePayload.Call[] memory c) {
        c = new CCIPGovernancePayload.Call[](1);
        c[0] = CCIPGovernancePayload.Call(target, data);
    }
}
