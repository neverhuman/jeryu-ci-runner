# Runtime closure producer

Run dependency installation and this producer inside an admitted build guest.
Keep its CI filesystem separate from the runtime rootfs: the runtime has no
`/home/ubuntu`, provider credentials or provider bindings. Preserve input
package/source pins, archives, notices, install recipes and tool receipts.

After staging the complete reviewed payload, run
`jeryu-inventory-runtime-closure /absolute/staging/root`, then
`jeryu-compose-runtime-class test /absolute/staging/root`. Inventory measures
protected files through retained descriptors; it never runs staged programs,
loaders, package hooks or `ldd`. It creates
`etc/jeryu/runtime-closure.json` exclusively with mode0444; its containing public
image directories are0755. Keep the inventory and composition binary hashes in
the producer receipt. The producer's descriptor limit must cover the bounded
inventory plus128 handles.

The internal `jeryu.runtime-closure.v1` receipt contains `architecture`, `files`
and explicit `aliases`. Every regular file records its absolute image path,
`sha256` identity, `bytes`, exact `mode`, optional `elf` declarations and a
`dependencies` map from needed library name to its resolved image path. ELF
declarations are `kind`, `interpreter`, sorted `needed`, `soname`, `rpath` and
`runpath`. Absolute symlink targets refer to the image root. Relative targets
resolve from their parent within the reviewed compiler/library/certificate
roots. Duplicate keys/targets, cycles and escapes fail.

The composer compares hashes, modes, complete file/alias membership and static
ELF64 declarations. Library edges must bind declared shared objects and SONAMEs
through approved loader search paths. Direct script interpreters must be bound
ELFs; ambient env-selected launchers need a separate reviewed producer policy.
The stage has no loader cache or hardware-capability library overrides. The
composer retains verified file descriptors through durable class composition.
It validates closure before creating overlay data and writes readiness last.
A failed inventory or composition remains failed evidence; keep its stage/logs.

Required payload includes Git and HTTPS helper/templates, Rust/Cargo,
compiler/linker, Bash/sh/echo/nohup, public CA roots, C.UTF-8 data, and exact0555
native CLI files reachable as `/usr/bin/claude`, `/usr/bin/codex`, `/usr/bin/grok`:

| Candidate | Bytes | SHA-256 |
| --- | ---: | --- |
| Claude Code2.1.289 | 246107320 | a186b99e4a9c88366cd49df2f7dad56c61fc306ef0140b19ee64b7c42a8d1348 |
| Codex0.161.0 | 292309256 | 9a820c17865fa825d04db416818679a9d63bd72e50835c396f496e5684626c9c |
| Grok1.0.46 | 171207616 | 41626a53292324140b92556b9d42ff5542e3dcd04aff85eafb8689dd4adb44fc |

Full selected distribution resources and notices belong in the inventory.
These are preserved x86_64 candidate pins, not current-version or publisher
qualification claims. Another architecture requires separately reviewed pins.
Lane P still owns the missing Claude packet, complete distribution/provenance,
provider adapters and authentication qualification. No real profile is enabled
by inventory/composition; fixed TEST mock bytes and zero bindings stay unchanged.

Pack only verified owned staging and sign the canonical manifest with the fresh
enrolled TEST authority. Bind packed rootfs, closure, recipe, tools and source
identities in the delivered artifact receipts. A measurement receipt alone
does not establish provenance, signed image readiness or provider acceptance.

Guest verification remains mandatory: actual Git checkout/replay, native and
Rust smoke builds, public TLS/locale/loopback behavior, fixed mocks as UID1000,
and Stop/checkpoint/resume/guard cleanup. Real Claude/Codex/Grok Firecracker
acceptance additionally needs qualified adapters, legitimate reusable auth,
the guest-built product stack and exact-head protected checks/review. Preserve
host source and mock evidence as their own proof scopes.
