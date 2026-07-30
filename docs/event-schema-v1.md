# TruthBounty event schema v1

The canonical event declarations are defined in `contracts/interfaces/ITruthBountyEvents.sol`. Every event carries a `uint16 version` value of `1` and a block-context `uint64 timestamp`.

## Claims

- `ClaimCreatedV1`: claim ID, actor, metadata hash, timestamp, version.
- `ClaimUpdatedV1`: claim ID, actor, metadata hash, timestamp, version.
- `ClaimResolvedV1`: claim ID, actor, outcome, timestamp, version.
- `ClaimFinalizedV1`: claim ID, actor, timestamp, version.

## Verification

- `VerificationSubmittedV1`: claim ID, verifier, support flag, stake amount, timestamp, version.
- `VerificationChallengedV1`: claim ID, challenger, reason hash, timestamp, version.

## Staking and slashing

- `StakeDepositedV1`: verifier, amount, resulting balance, timestamp, version.
- `StakeWithdrawnV1`: verifier, amount, resulting balance, timestamp, version.
- `SlashExecutedV1`: claim ID, verifier, reason hash, amount, timestamp, version.

## Rewards and treasury

- `RewardCalculatedV1`: claim ID, recipient, amount, timestamp, version.
- `RewardEscrowedV1`: claim ID, recipient, amount, timestamp, version.
- `RewardClaimedV1`: claim ID, recipient, amount, timestamp, version.
- `TreasuryTransferV1`: operation ID, token, recipient, amount, timestamp, version.

## Governance and emergency

- `GovernanceProposalCreatedV1`: proposal ID, proposer, metadata hash, timestamp, version.
- `GovernanceProposalExecutedV1`: proposal ID, executor, timestamp, version.
- `EmergencyPauseActivatedV1`: actor, reason hash, timestamp, version.
- `EmergencyPauseRecoveredV1`: actor, timestamp, version.

The first three indexed parameters are chosen for entity, actor, and reason or metadata filtering where applicable. Consumers must use the complete event signature because event names may coexist with legacy signatures during migration.