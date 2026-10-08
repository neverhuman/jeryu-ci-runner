# Encrypted workspace checkpoint formats

`CheckpointManifest.format` selects the disk encoding. Missing format means
`legacy_dense_v1`; serializers omit that default so retained old JSON and its
reference digest stay unchanged. Legacy `JERYUCP1` encryption/read bytes are
unchanged. New retention emits `sparse_v2`; older binaries reject that field.
Never roll back to a binary without the sparse reader while sparse references
remain retained. This local candidate has no release or lifecycle acceptance.

Sparse v2 has a 24-byte header: `JERYUCP2`, big-endian logical size (u64), and
a random 8-byte nonce prefix. Canonical records have 16-byte metadata:
logical offset (u64), plaintext length (u32), sequence (u32), all big-endian.
A data record holds one aligned 1 MiB block, except the exact final partial
block, followed by its 16-byte AES-256-GCM tag. Zero blocks are omitted.
Offsets strictly increase, sequences begin at zero and are contiguous, and
record count cannot exceed ceil(logical size / 1 MiB). The authenticated end
record has offset equal to logical size, zero length, next sequence, and one
16-byte tag over empty plaintext. It is required even for an all-hole disk.
No trailing bytes are accepted. Logical disks are bounded to 1 TiB.

AEAD associated data is `jeryu.checkpoint.sparse.v2` plus NUL, the exact
header, binding length (u64), exact existing checkpoint/context/flush/workspace
binding bytes, metadata, and kind (0 data, 1 end). Nonces are prefix plus
sequence (u32). Each retain attempt has a fresh random key; fallback never
rewinds an already written sequence. Plaintext SHA-256 is domain separated by
`jeryu.checkpoint.sparse.plaintext.v2` plus NUL and logical size, then each
canonical nonzero record's offset, length and bytes. Ciphertext digest covers
all exact header, metadata, payload and tag bytes. Omitted blocks mean zero.
The plaintext digest therefore differs from the legacy full-disk hash.

SEEK_DATA/SEEK_HOLE discover candidate blocks in the opaque disk file without
mounting the guest filesystem. Allocated zero blocks are omitted after reading.
Unsupported extent operations switch to dense block traversal using the same
canonical format and counters; other errors fail retention. Restore truncates
only the caller-owned new successor disk, sets its exact logical size, then
writes authenticated nonzero blocks. Failures cannot produce a ready workspace;
existing owned-resource cleanup destroys the untrusted successor on failure.
Quota remains conservative logical size + ceil(size / 1 MiB) * 32 + 72 bytes,
plus 1 MiB key/manifest/filesystem bookkeeping. Buffers hold at most one block
plus its tag; no extent list or plaintext disk copy is accumulated in memory.

Verification belongs to microVM sparse unit tests, the protocol legacy/default
round trip, authoritative `generate_v2_schema`, and full contract drift.
Real 16 GiB stop/resume timing, recovery and complete security gates remain
separate actual-KVM acceptance and cannot be inferred from unit tests.
