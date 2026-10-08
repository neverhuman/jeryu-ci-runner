# Firecracker runtime image composition

The runtime is Firecracker/Jailer 1.17.0 with a signed exact kernel/rootfs/guestd
identity. This directory owns the fixed image-class overlay and credential-free
test agents. It does not download provider CLIs or execute repository recipes.
Dependency installation, package hooks and tool builds must run in build VMs.

The trusted image builder runs the Rust jeryu-compose-runtime-class binary exactly once on its
root-owned unmounted staging tree before packing/signing it. The closed CLI is
`jeryu-compose-runtime-class production|test /absolute/staging/root`. All parent
directories are verified and subsequent operations use no-follow directory
descriptors; existing markers and mock targets are never replaced. Test mock
bytes are embedded from the fixed repository file, installed before the marker,
and synced with fixed 0555/0444 modes regardless of the builder umask. Production refuses
any usr/lib/jeryu/mock object, including dangling links. Test installs the fixed
mock-agent script there. Both add etc/jeryu/runtime-image-class, checked by guestd
before Ready. The signed manifest must declare the matching image_class and
sorted profile_ids. Production runtime admission never trusts the test signer;
test nodes explicitly enroll a different test key and carry no provider binding.

The three mock profiles edit a C file and compile/run it as uid 1000. Their names
identify test cases, not provider emulation. They invoke no model, authentication,
network endpoint, credential helper or real CLI. The production profile registry
does not enable Claude/Codex/Grok yet. Lane P owns pinned CLI adapters and native
authentication qualification outside public PR CI.

Packing uses the trusted producer's fixed filesystem tool on reviewed staging
bytes. Nodes verify exact signed digests and never mount guest-controlled disks.
Complete canonical environment builds, signed release provenance, warm snapshot
qualification and a production default-resource load test remain outstanding.
The development evidence builder is not a production environment readiness proof.
