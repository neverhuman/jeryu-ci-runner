# ADR 0004: release-tag gating in pr-gate

Status: Proposed (design only; an owner must agree it before any code lands)
Date: 2026-10-29

Two attempts to add release-tag gating to the pr-gate runner were held and then
parked: PR #151 (tag-lock descriptor collision, finality that was not a verdict)
and its rework #153 at commit `41b5400`, whose review found two further
high-severity defects. Both attempts wrote the mechanism first and the rules
afterwards. This ADR writes the rules first. It decides admission, provenance,
cost, the proof base and finality, so that the implementation PRs listed at the
end are small, each provable by a test, and none of them has to re-open a
question settled here.

The parked branch is `todo/20261029-154701-43d5d5` (head `9bface0`). It is a
reference for the shape of the Git and forge plumbing only; every rule below
differs from what it does.

## What a release tag is allowed to be

A tag is a *trigger*, never an authority. Anybody with write access can create
or force-move `refs/tags/v9.9.9`, and tag refs are not protected. Both parked
attempts treated the existence of such a ref as enough to execute the tagged
commit's own recipe on the gate host and to publish a final, required verdict on
it. That is the defect behind most of the others, so the rules start there.

### Admission

A tag candidate is admitted only when all of these hold, and each is re-checked
immediately before the head is claimed, as the protected-branch path already
re-checks protection:

- the ref matches the release-ref grammar (`v<digit>…` or `<repo>-v<digit>…`,
  `git check-ref-format`, at most 240 bytes) and peels to a 40-hex commit;
- the forge's ref listing reports at least one **protected branch** of that
  repository, and the commit is contained in one of them. Containment is decided
  locally, in the host's own mirror after it is fetched, with
  `git merge-base --is-ancestor <sha> refs/remotes/origin/<branch>`, and only
  against a branch whose tip the forge reported as protected at that exact sha
  (`gate_ref_protection` answers `"<sha> protected"`). A tag on a commit that
  has not landed on a protected branch is not gated, and the reason is said;
- the commit was neither authored nor committed by the runner's own identity,
  as every other gate path requires;
- the containing branch yields a usable proof base (see *Base* below).

Anything the forge cannot answer leaves the repository's tags for the next tick.
No tag is gated on a forge that does not serve the ref listing, which is also
the required degraded mode for an older forge: it costs that forge nothing.

Consequence to accept deliberately: a release tag is gateable only after its
commit has landed on a protected branch. Tagging an unlanded commit gets no
verdict rather than a free execution. That is the fail-closed direction and it
is what makes the rest of this design safe.

### Provenance

Provenance decides the sandbox boundary: an internal commit's recipe runs on the
gate host, a contributed one only inside `PR_GATE_SANDBOX_COMMAND`. In `41b5400`
`gate_tag_contributed` read one unpaginated `pulls?state=all` page and printed
`0` ("internal") when no row matched the commit — so a repository with more
than one page of pull requests, which every served repository has, executed
contributed code unsandboxed as the user owning the forge credentials. The
answers are three, not two, and the third is not "internal":

- **contributed** — a pull-request row carrying `CONTRIBUTED_LABEL` has this
  commit as its head; the contributed rules then apply unchanged, including
  `gate_contribution_refusal` (an ok-to-test allowance from a configured
  maintainer naming this exact commit, and a configured sandbox). A tag will
  normally be refused here, and that is correct: a contribution is admitted by
  its pull request, not by somebody tagging it.
- **internal** — a row without that label has this commit as its head.
- **undetermined** — no row names the commit within the page budget, or the
  forge answered anything but 200. The tag is not gated; the runner says so once
  for that repository and the next tick tries again. `undetermined` must never
  collapse into `internal`.

Listing is explicit and paginated, as `pr-gate-audit.sh` already does:
`pulls?state=all&per_page=<n>&page=<p>`, newest first as the forge orders them,
stopping at the first short page. The budget is
`PR_GATE_TAG_PR_PAGES` × `per_page` rows (default 4 × 500); a landed release
commit's pull request is among the newest rows, and a budget exhausted without a
match is `undetermined`, not `internal`.

### Cost

`41b5400` issued one full `pulls?state=all` listing per discovered tag — up to
64 per repository per tick, every tick, in every background slot, before any
gating and whether or not any tag would be gated. A 429 from any of them starts
the host-wide GET back-off that stalls pull-request gating for every slot. Three
rules bound it:

- **Discovery reads Git, not the forge.** `git ls-remote --tags` with its
  existing `timeout`, one call per repository per tick, is the whole of
  discovery. Candidate rows carry the ref and the commit and no provenance.
- **Provenance is resolved once, for the one candidate about to be gated**,
  after finality and candidate selection have dropped the rest — at most one
  pull-request listing per tick, cached per repository for the tick in an
  associative array, as `refs_seen` caches ref listings.
- **A back-off suppresses tag work.** When `backoff_remaining` is non-zero, or
  the host-wide tag lock is already held by another slot, the tick does no tag
  discovery at all. A 429 is never counted as a tag failure or a verdict.

### Base

Tag candidates in `41b5400` carried base `-`, which `resolve_proof_base` maps to
`main`. A release line does not descend from main — the exact failure the
proof-base machinery was built to prevent — so every release-line tag failed its
base-relative checks, and finality made that failure permanent.

The base of a tag is the protected branch admission proved contains the commit.
When several do, the default branch wins if it is one of them, otherwise the
lexicographically first, and the status names the branch chosen. That branch is
passed as the candidate's base, so the existing protected-branch rule in
`resolve_proof_base` binds `origin/<branch>` and `gate_fetch_base` fetches it at
the sha bound into the inputs. As on the protected-branch path, an owner with no
`PR_GATE_PROOF_BASE_VARS` entry is refused rather than gated against main: a
release tag is never silently proved against an unrelated history.

### Finality

A tag's verdict is final — the point of the feature, since a toolchain change
must not re-build every old release — but finality is the strongest authority
the runner has, so it needs the strictest evidence and a self-service exit.

- **Only a verdict, from an identified creator.** Finality requires the newest
  `<repo>/required` status of this gate identity to be `success` or `failure`,
  to name the `release-tag` ref, to name the inputs digest of the identity being
  decided, and to carry a non-empty `.creator.login` — the same rule
  `gate_newest_names_inputs` applies to reuse. A creator-less row counts only by
  its description, which anyone who can post a status can write, and must not
  freeze a gate. `error`, interrupted and `inputs_changed` outcomes are never
  final.
- **Decided before any tree work.** The verdict is checked while candidates are
  chosen, from the status snapshot that path already reads, and a final tag is
  dropped from the candidate list. In `41b5400` the check ran after the slot tree
  had been checked out at the tag's commit and the whole tree re-hashed, so every
  final tag reset and re-fingerprinted the shared slot tree on every tick
  forever. Nothing sets `retry_wanted` for tag work, so the cheap
  mirror-only reuse path stays available to a tag that is not final.
- **Two ways out, one of them self-service.** `PR_GATE_REGATE_TAG=<full sha>`
  lifts finality for that commit in one invocation (shell access), and the
  forge's own re-gate request (`gate_regate_wanted`), which every other path
  honours, lifts it too. A flaky release failure must be recoverable by the
  people who own the release, not only by someone with a shell on the gate host.

### The smaller rules the reviews raised

- The adoption path writes its `tag-adopted.json` receipt *before* it posts, and
  a non-5xx refusal of that post is reported and retried on the next tick rather
  than killing the tick: the current `post_status` dies on 4xx, and adoption runs
  before `gate_begin`, so there is nothing for `gate_recover` to republish.
- The host-wide tag lock takes a named descriptor (`exec {tag_lock_fd}>`), not
  fd 5, which `dispatch_take` uses for the dispatch lock. The lock is held across
  a multi-hour build; a future `dispatch_take` inside the loop would otherwise
  drop it silently and allow two concurrent tag builds.
- The sandboxed tag build gets the documented background priority
  (`"${priority[@]}"`, niceness 19 and idle I/O), which only the non-sandbox and
  cache invocations received.
- Every forge and Git read on the tag path has a timeout, including the
  admission re-read.

## Implementation: one rule per pull request, each with its tests

The tests are `ops/pr-gate/tests/` cases against the fixture forge and local Git
repositories, in the suite's existing style; each PR extends `tests/required.sh`.

1. **Discovery and admission.** Release-ref grammar, `ls-remote` paging, the
   protected-branch containment rule, identity refusal, re-check at claim time.
   Tests: a tag on an unlanded commit is not gated; a tag on a commit contained
   in a protected branch is admitted; a forge that serves no ref listing gates
   no tags; a branch the forge reports unprotected admits nothing; a tag moved
   between listing and claim is dropped.
2. **Provenance.** The three-valued answer, paging to the budget, newest-first,
   `undetermined` on a short budget or a non-200. Tests: a contributed head is
   refused without an allowance; an internal head runs unsandboxed; a commit
   whose row is on page 3 is still found; a commit on page 9 is `undetermined`
   and the tag waits; a 500 leaves the tag waiting.
3. **Cost.** One `ls-remote` and at most one pull-request listing per repository
   per tick; no tag work while a back-off or the tag lock is in force. Tests:
   request counts from the fixture forge for a repository with 64 tags; a tick
   under back-off issues none.
4. **Base.** The containing branch as the proof base, the choice rule, refusal
   without a `PR_GATE_PROOF_BASE_VARS` entry. Tests: a release-line tag is proved
   against its release branch; the recipe receives `<var>=origin/<branch>`; the
   status names the branch; an unconfigured owner is refused.
5. **Finality.** Verdict-only, creator-required, pre-tree, both lifts. Tests: a
   creator-less marker status does not make a verdict final; an `error` status
   does not; a final tag prepares no tree and re-hashes nothing; a forge re-gate
   request re-gates it; `PR_GATE_REGATE_TAG` re-gates it.
6. **The smaller rules.** Receipt before publication and a retried adoption post,
   the named lock descriptor, background priority in the sandbox branch, the
   remaining timeouts. Tests: a 4xx on the adoption post leaves a receipt and no
   dead tick; the lock survives a `dispatch_take`; the sandbox invocation carries
   the priority prefix.

`ops/pr-gate/README.md` gains the operator-facing section (what is discovered,
what is admitted, what is final, how to re-gate) in PR 1 and is corrected by each
later PR, so the README never documents behaviour that is not yet in the runner.
`VERSION` is a minor bump in PR 1 and stays there: the later PRs add no setting
beyond `PR_GATE_TAG_PR_PAGES`, which PR 2 introduces with a default.
