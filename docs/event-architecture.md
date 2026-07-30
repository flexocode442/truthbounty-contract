# TruthBounty On-Chain Event Architecture

## Status

Schema version: `1`

This document defines the canonical event contract between TruthBounty smart contracts and off-chain consumers such as indexers, explorers, APIs, analytics services, notification systems, and frontends.

The Solidity source of truth is `contracts/interfaces/ITruthBountyEvents.sol`.

## Design rules

1. Events are emitted only after the corresponding state transition succeeds.
2. Event names use past-tense domain actions such as `ClaimCreatedV1` and `RewardClaimedV1`.
3. Entity identifiers, actors, and stable lookup keys are indexed where practical.
4. Dynamic metadata is referenced by a deterministic `bytes32` hash rather than duplicated in logs.
5. Every canonical event includes a block-context timestamp and schema version.
6. A single state transition emits one canonical event unless the transition intentionally spans multiple protocol domains.
7. Failed or reverted transactions emit no canonical events.
8. New schema versions must be additive whenever possible. Existing event signatures are immutable once consumed in production.

## Common fields

- `timestamp`: `uint64(block.timestamp)` at emission time.
- `version`: `EVENT_SCHEMA_VERSION` from `ITruthBountyEvents`.
- `actor`: the address responsible for the state transition.
- `metadataHash`: a deterministic hash of off-chain or dynamic metadata.
- `reason`: a stable `bytes32` identifier, not free-form text.

## Event ordering

Within one transaction, consumers may rely on log order. Across transactions, consumers must order by block number, transaction index, and log index.

Business logic must not depend on event ordering. Events reflect completed state changes; they do not authorize or trigger on-chain state transitions.

## Event catalogue

### Claims

- `ClaimCreatedV1`: a new claim is persisted.
- `ClaimUpdatedV1`: claim metadata changes.
- `ClaimResolvedV1`: the canonical outcome is determined.
- `ClaimFinalizedV1`: settlement and all required accounting are complete.

### Verification

- `VerificationSubmittedV1`: a verifier records a position and stake.
- `VerificationChallengedV1`: a verification or claim is challenged.

### Staking and slashing

- `StakeDepositedV1`: verifier collateral increases.
- `StakeWithdrawnV1`: verifier collateral decreases through a valid withdrawal.
- `SlashExecutedV1`: locked collateral is confiscated for a unique offence.

### Rewards and treasury

- `RewardCalculatedV1`: a deterministic reward amount is established.
- `RewardEscrowedV1`: funds become reserved for a recipient.
- `RewardClaimedV1`: reserved funds are transferred or marked paid.
- `TreasuryTransferV1`: treasury-controlled value moves for a uniquely identified operation.

### Governance and emergency controls

- `GovernanceProposalCreatedV1`: a governance proposal is registered.
- `GovernanceProposalExecutedV1`: an approved proposal is executed.
- `EmergencyPauseActivatedV1`: protocol emergency controls are activated.
- `EmergencyPauseRecoveredV1`: normal operation is restored.

## Indexing guidance

Indexers should persist the tuple `(chainId, contractAddress, transactionHash, logIndex)` as the unique event identity. Reorg handling must roll back events from orphaned blocks before replaying the canonical chain.

Consumers should filter by indexed entity IDs and actor addresses, then validate the `version` field before decoding version-specific semantics.

## Versioning policy

Version 1 consumers must ignore unknown event signatures and reject unsupported versions only for events they recognize. A new incompatible payload requires a new event signature and a new schema version; existing signatures must not be silently repurposed.

## Gas guidance

Only fields required for filtering should be indexed. Large strings and byte arrays should not be emitted when a content hash or stable identifier is sufficient. Gas benchmarks should compare state-changing functions before and after canonical event adoption.
