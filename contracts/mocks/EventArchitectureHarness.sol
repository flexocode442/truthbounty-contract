// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/ITruthBountyEvents.sol";

contract EventArchitectureHarness is ITruthBountyEvents {
    uint16 public constant EVENT_SCHEMA_VERSION = 1;

    function emitClaimCreatedV1(
        uint256 claimId,
        address actor,
        bytes32 metadataHash
    ) external {
        emit ClaimCreatedV1(
            claimId,
            actor,
            metadataHash,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    function emitVerificationSubmittedV1(
        uint256 claimId,
        address verifier,
        bool support,
        uint256 stakeAmount
    ) external {
        emit VerificationSubmittedV1(
            claimId,
            verifier,
            support,
            stakeAmount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }

    function emitSlashExecutedV1(
        uint256 claimId,
        address verifier,
        bytes32 reason,
        uint256 amount
    ) external {
        emit SlashExecutedV1(
            claimId,
            verifier,
            reason,
            amount,
            uint64(block.timestamp),
            EVENT_SCHEMA_VERSION
        );
    }
}
