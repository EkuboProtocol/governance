// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IAny2EVMMessageReceiver} from "./IAny2EVMMessageReceiver.sol";

interface IAny2EVMMessageReceiverV2 is IAny2EVMMessageReceiver {
  /// @notice Get the CCV configuration & allowed finality config for a source chain and sender.
  /// @dev Implementations must return an appropriate allowedFinalityConfig value. Returning
  /// FinalityCodec.WAIT_FOR_FINALITY_FLAG signals that only fully finalized messages are accepted. Returning a non-zero
  /// value allows faster-than-finality (FTF) messages whose requested finality is permitted by the
  /// allowedFinalityConfig (see `FinalityCodec._ensureRequestedFinalityAllowed`).
  /// When a trusted sender is used (and verified by the receiver), this is less critical as the trusted sender
  /// will only send messages with a certain level of finality. The simplest way to implement this is to either allow FTF
  /// messages when sender-verification is used, or require finality for all messages. That means the config can be a
  /// simple boolean instead of n^2 config where for each source, an allowed finality config must be chosen.
  ///
  /// A few methods to check the finality requirement are:
  /// - Only allow trusted senders, allow FTF broadly as the senders will decide on the final value
  /// - Return a single config for all chains
  /// - Return a config specific to the source chain (e.g. 10 blocks for chain A, 20 blocks for chain B)
  /// - Do not allow FTF messages at all, always return the WAIT_FOR_FINALITY_FLAG.
  ///
  /// @param sourceChainSelector The source chain selector of the incoming message. This can be used to specify
  /// different CCV requirements for different source chains, and provides context for the allowed finality config.
  /// @param sender The sender of the message on the source chain. This can be used to implement sender-specific
  /// security policies, such as allowing FTF only for trusted senders.
  /// @dev Messages are executable when either the required finality has been reached, or the chain has marked the
  /// block as finalized. Whichever one comes first will allow the message to be executed.
  /// @return requiredCCVs The list of required CCVs for messages from this source chain. All of these CCVs must pass
  /// verification for a message to be accepted.
  /// @return optionalCCVs The list of optional CCVs for messages from this source chain. These CCVs can be used to
  /// increase the security of messages from this source chain, but are not strictly required. If any optional CCVs are
  /// included, the optionalThreshold parameter must also be set to indicate how many of the optional CCVs must pass
  /// verification for a message to be accepted.
  /// @return optionalThreshold The number of optional CCVs that must pass verification for a message to be accepted.
  /// @return allowedFinalityConfig The allowed finality config, encoded according to the `FinalityCodec`. This allows
  /// the receiver to specify which finality configs are accepted for messages from this source chain.
  function getCCVsAndFinalityConfig(
    uint64 sourceChainSelector,
    bytes calldata sender
  )
    external
    view
    returns (
      address[] memory requiredCCVs,
      address[] memory optionalCCVs,
      uint8 optionalThreshold,
      bytes4 allowedFinalityConfig
    );
}
