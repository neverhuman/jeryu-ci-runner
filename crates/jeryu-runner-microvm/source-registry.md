# Source-bundle registry (K4)

This is an opaque source-byte registry, not a repository authorization or build
service. The control plane resolves protected main and produces a Git bundle.
The guest validates the bundle and performs preparation/rebase before launching
an agent. Registered bytes alone never create a session or qualify an image.

`SourceBundleRegistry::open` requires root custody, the node state's filesystem,
a separate `source_bundle_budget_gib` allocation (1..64), and an exclusive
registry lock. Existing source objects are counted at startup. Each object or
reservation charges its stored length plus 64 KiB for metadata; at most 4096
objects and four active uploads are admitted. This allocation is separate from
the node's VM disk budget. Operators must provision both after host reserve.

Staging reserves physical space through the node admission mutex. Both upload
and VM admission include all outstanding upload promises and the unallocated
portion of existing sparse workspace/checkpoint promises. Allocated immutable
objects already reduce available filesystem space. Cancellation stops writes
and drops only the exclusive stage. No upload path mounts a guest filesystem,
executes a recipe, parses a Git configuration, or selects an executable role.

The mTLS endpoint validates the exact enrolled control-plane leaf certificate
before HTTP parsing. It permits one request per connection and rejects cookies,
authorization, queries, compression, chunked upload encoding, duplicate framing
headers, invalid metadata and oversized objects. Metadata has a 16 KiB bound;
data frames have a 64 KiB bound, five-second idle deadline and the connection's
75-second total deadline. Disk I/O stays off the async runtime. Accepted upload
stages are bounded independently of the 32-connection transport limit.

Before data creation, a durable root-owned UUID journal records the closed
BundleUpload metadata. Every byte is hashed, and every padding byte must be
zero. After exact length and digest verification, data is synced, made read-only
and atomically renamed with NOREPLACE into `<full-sha256>/source-bundle`.
Directory sync precedes journal removal. An existing object must have correct
custody, length and the exact full digest. It is never replaced; an identical
upload returns the same BundleRegistered receipt without changing its inode.

Startup reconciles only data files authorized by valid bounded root-owned UUID
journals. Corrupt/unknown files are preserved and visibly block new uploads;
later valid journals still reconcile. A fixed error is logged without request
body or input values. Source objects are not evicted by an RPC; a future trusted
ownership/retention policy is needed for eviction. A full registry fails visibly.

Development qualification:

```sh
source ops/ci/hosted-git-env.sh
cargo test --locked -p jeryu-runner-protocol
cargo test --locked -p jeryu-runner-microvm --lib
cargo test --locked -p jeryu-runnerd --lib --bins
cargo build --locked --release -p jeryu-runner-microvm --example live_registry
```

The root-only live_registry driver requires the fixed dedicated development
node and checks immutable/idempotent publication, capacity, negative bodies,
collision preservation and mixed corrupt/valid startup recovery. It uses only
trusted temporary byte fixtures. Actual HTTPS plus VM boot needs the separate
development KVM evidence lane. Neither this driver nor a registered object
proves authoritative forge resolution, product clients, provider credentials,
production provenance, protected gates, or complete legacy-launch migration.
