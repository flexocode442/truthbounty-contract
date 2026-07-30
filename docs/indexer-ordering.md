# Deterministic event ordering

TruthBounty event consumers must process canonical logs using the following total order:

1. block number
2. transaction index
3. log index

Within one successful transaction, events are emitted only after the state mutation they describe. A consumer must not assume ordering across separate transactions beyond the canonical block ordering above.

Consumers should store the block hash with each event. When a reorganization replaces a block, all events associated with the orphaned block hash must be rolled back before events from the replacement branch are applied.

Duplicate delivery is expected in distributed systems. Consumers must make ingestion idempotent by using chain ID, transaction hash, and log index as the event identity.

Version upgrades do not change the ordering rule. Unsupported versions should be quarantined for later decoding rather than interpreted using an older schema.