# Event gas benchmarks

This document defines the repeatable benchmark method for the SC-022 event schema.

## Method

Run the focused Hardhat suite with gas reporting enabled for the event harness. Measure transaction gas for each isolated event emission and compare it with a no-op baseline compiled with the same Solidity version, optimizer settings, IR pipeline, and Cancun EVM target.

```bash
REPORT_GAS=true npx hardhat test test/EventArchitecture.test.ts
```

Record the compiler version, optimizer runs, EVM target, event signature, indexed topic count, encoded data size, total transaction gas, and baseline-adjusted event overhead.

## Required cases

- `ClaimCreatedV1`: three indexed fields plus timestamp and schema version.
- `VerificationSubmittedV1`: claim and verifier filters plus vote payload.
- `SlashExecutedV1`: claim, verifier, and reason filters plus amount payload.
- Governance and emergency events when their protocol modules adopt the canonical interface.

## Interpretation

Indexed parameters improve query performance but consume additional topic gas. Dynamic metadata is represented by a `bytes32` reference rather than duplicated strings. Benchmarks must be rerun whenever an event signature, indexed field, compiler configuration, or protocol schema version changes.

The canonical schema version for the initial SC-022 event surface is `1`.