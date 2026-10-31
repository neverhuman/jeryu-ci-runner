#!/usr/bin/env bash
# Guards shared by the proof lane and its offline regression tests
# (ops/ci/tests/test-proof-guards.sh).

# Give this checkout the history the lane's ancestry check and its
# `git diff origin/main...HEAD` need, then refresh protected main.
#
# A depth-1 CI checkout has a grafted head: its own parents are absent. A fetch
# that names only `main` deepens main and can leave the head's graft in place,
# and then every ancestry question about the head answers "no". `--unshallow`
# with the remote's whole refspec deepens every ref the forge serves, the head's
# branch among them. A checkout still shallow after that (a head the forge does
# not serve) is refused rather than asked a question it cannot answer.
#
# The caller checks that `origin` is the hosted source repository first: this
# is the lane's only network operation against it.
proof_require_history() {
  local shallow
  shallow="$(git rev-parse --is-shallow-repository)" || return 1
  case "$shallow" in
    true)
      git fetch --quiet --no-tags --unshallow origin || return 1
      if [[ "$(git rev-parse --is-shallow-repository)" != false ]]; then
        printf 'proof checkout is still shallow after fetching every ref the forge serves\n' >&2
        return 1
      fi
      ;;
    false) ;;
    *) printf 'cannot determine proof checkout history\n' >&2; return 1 ;;
  esac
  # Refresh the protected ref explicitly: a checkout's remote-tracking main
  # may be absent or older than the main used by the forge baseline audit.
  git fetch --quiet --no-tags origin '+refs/heads/main:refs/remotes/origin/main'
}

# Normal runs judge against refreshed protected main. A prior-tip retry is valid
# only when HEAD is that exact refreshed tip. Resolve its parent to a commit now:
# later fetches cannot turn a moving origin/main~1 into HEAD and empty the proof.
proof_base_ref() {
  local ref="${JERYU_JANKURAI_BASE_REF:-origin/main}" head main parent
  case "$ref" in
    origin/main) printf '%s\n' "$ref" ;;
    origin/main~1)
      head=$(git rev-parse --verify 'HEAD^{commit}') || return 1
      main=$(git rev-parse --verify 'refs/remotes/origin/main^{commit}') || return 1
      [[ "$head" == "$main" ]] || {
        printf 'prior-tip proof requires HEAD to equal refreshed protected main; main moved or this is a PR\n' >&2
        return 1
      }
      parent=$(git rev-parse --verify "$head^1") || return 1
      printf '%s\n' "$parent" ;;
    *) printf 'proof base must be protected origin/main, or origin/main~1 for an exact main-tip retry, got %s\n' \
         "$ref" >&2; return 1 ;;
  esac
}

# Print the fork point of HEAD_COMMIT from protected main's tip BASE_COMMIT.
# The change set is judged from here, so a head behind the tip is not refused,
# and main's own head (or any ancestor of the tip) has the tip's ancestor as its
# fork point and changes nothing. Only a head with no shared history fails.
proof_fork_point() {
  local base="$1" head="$2" fork
  fork="$(git merge-base "$base" "$head")" && [[ "$fork" =~ ^[0-9a-f]{40}$ ]] || {
    printf 'proof head shares no history with protected base: base=%s head=%s\n' \
      "$base" "$head" >&2
    return 1
  }
  printf '%s\n' "$fork"
}

# Write the NUL-separated paths HEAD_COMMIT changes since FORK_COMMIT to OUT.
# The diff goes to a file first, so a failing git diff fails the caller under
# set -e instead of leaving an empty change set behind a process substitution.
# An empty OUT is a change set of nothing, not an error.
proof_changed_paths() {
  local fork="$1" head="$2" out="$3"
  git diff --no-ext-diff --name-only -z --diff-filter=ACDMRT \
    "${fork}...${head}" >"$out.unsorted" || return 1
  LC_ALL=C sort -zu "$out.unsorted" >"$out" || return 1
  rm -f -- "$out.unsorted"
}

# Print FILE's sha256 as a JSON string; fails when FILE cannot be read.
proof_json_digest() {
  local sum
  sum="$(sha256sum -- "$1")" || return 1
  printf '"%s"\n' "${sum%% *}"
}

# Advisory proof reports use Git's variable-length abbreviation. Bind only a
# hexadecimal prefix that resolves to exactly this commit, never a named ref
# or a prefix ambiguous with another Git object.
proof_require_report_head() {
  local repo="$1" expected="$2" report="$3" reported objects
  reported="$(jq -er '.git_head | strings' "$report")" || {
    printf 'cannot read proof report head: %s\n' "$report" >&2
    return 1
  }
  if [[ ! "$reported" =~ ^[0-9a-f]{7,40}$ || "$expected" != "$reported"* ]]; then
    printf 'proof report does not name the exact head: %s\n' "$report" >&2
    return 1
  fi
  objects="$(git -C "$repo" rev-parse --disambiguate="$reported")" || return 1
  [[ "$objects" == "$expected" ]] || {
    printf 'proof report head is missing or ambiguous: %s\n' "$report" >&2
    return 1
  }
}

# Print the lane's summary, jeryu.ci-runner.proof-evidence/v2, from the
# artifacts under ./target this run wrote.
#
# Arguments: HEAD BASE FORK RECEIPT_DIR CHANGED_COUNT RECEIPT_COUNT
# BASELINE_SCORE BASELINE_SHA256.
#
# v2 over v1: adds fork_point, and admits an empty change set (changed_path_count
# 0). Then there is no proof plan, evidence index, verification, receipt
# directory or proofmark receipt, so proof_plan_sha256, evidence_index_sha256,
# proof_verification_sha256, receipt_dir and proofmark_review_obligations are
# null, receipt_count is 0 and proof_verification is "not_applicable". With a
# non-empty change set every one of them must come from a file this run wrote,
# and proof_verification is "pass". Nothing in the family reads the summary
# today; jeryu-auto-tag reads only the <repo>/required status.
proof_evidence_summary() {
  local head="$1" base="$2" fork="$3" receipt_dir="$4" changed="$5" receipts="$6"
  local baseline_score="$7" baseline_sha256="$8"
  local plan=null index=null verification=null review=null dir=null verdict=not_applicable
  [[ "$changed" =~ ^[0-9]+$ && "$receipts" =~ ^[0-9]+$ ]] || {
    printf 'proof summary counts are not whole numbers: %s %s\n' "$changed" "$receipts" >&2
    return 1
  }
  if (( changed > 0 )); then
    (( receipts > 0 )) || { printf 'a non-empty change set has no proof receipts\n' >&2; return 1; }
    plan="$(proof_json_digest target/jankurai/proof-plan.json)" || return 1
    index="$(proof_json_digest target/jankurai/evidence-index.json)" || return 1
    verification="$(proof_json_digest target/jankurai/proof-verification.json)" || return 1
    review="$(jq -er '.summary.review_obligations | numbers' \
      target/jankurai/proofmark/proofmark-receipt.json)" || return 1
    dir="$(jq -n --arg d "$receipt_dir" '$d')"
    verdict=pass
  elif (( receipts != 0 )); then
    printf 'an empty change set cannot have proof receipts\n' >&2
    return 1
  fi
  jq -n \
    --arg head "$head" --arg base "$base" --arg fork "$fork" \
    --argjson receipt_dir "$dir" \
    --argjson plan_sha256 "$plan" \
    --argjson evidence_index_sha256 "$index" \
    --argjson verification_sha256 "$verification" \
    --arg proof_verification "$verdict" \
    --argjson proofmark_review "$review" \
    --arg security_sha256 "$(sha256sum target/jankurai/security/evidence.json | awk '{print $1}')" \
    --arg supply_chain_sha256 "$(sha256sum target/security/evidence.json | awk '{print $1}')" \
    --arg sbom_sha256 "$(sha256sum target/security/sbom.cdx.json | awk '{print $1}')" \
    --arg baseline_sha256 "$baseline_sha256" \
    --argjson changed_count "$changed" \
    --argjson receipt_count "$receipts" \
    --argjson baseline_score "$baseline_score" \
    --argjson migration_liability "$(jq -er .liability_score target/jankurai/migration-report.json)" \
    --argjson baseline_migration_liability "$(jq -er .liability_score target/jankurai/baseline-migration-report.json)" \
    '{schema_version:"jeryu.ci-runner.proof-evidence/v2",git_head:$head,
      base_commit:$base,fork_point:$fork,dirty_worktree:false,changed_path_count:$changed_count,
      receipt_count:$receipt_count,receipt_dir:$receipt_dir,
      proof_plan_sha256:$plan_sha256,evidence_index_sha256:$evidence_index_sha256,
      proof_verification_sha256:$verification_sha256,security_sha256:$security_sha256,
      supply_chain_sha256:$supply_chain_sha256,sbom_sha256:$sbom_sha256,
      baseline_score:$baseline_score,baseline_sha256:$baseline_sha256,
      migration_liability_score:$migration_liability,
      baseline_migration_liability_score:$baseline_migration_liability,
      proof_verification:$proof_verification,proofmark_mode:"advisory",
      proofmark_review_obligations:$proofmark_review,
      synthetic_fallbacks:0,conclusion:"success"}'
}

# Ratchet this head's migration analysis against protected main's.
#
# Both reports are held to the same shape, the one the pinned Jankurai 1.7.5
# `jankurai migrate <root> --analyze` writes (recorded in
# ops/ci/tests/fixtures/jankurai-1.7.5-migrate-analyze.json): schema 1.0.0,
# status "complete", a non-negative numeric liability_score and an array of
# required_proof_lanes. Each is bound to the tree it analysed by source_root.
# rollback_cutover_notes is free text the tool writes and is not gated.
#
# The head may not raise liability, and may drop one of main's required proof
# lanes only when its liability is strictly lower.
proof_require_migration() {
  local baseline="$1" baseline_root="$2" candidate="$3" candidate_root="$4"
  local shape liability lanes
  shape='.schema_version == "1.0.0" and .command == "jankurai migrate" and
    .status == "complete" and .source_root == $root and
    (.liability_score | type == "number" and . >= 0) and
    (.required_proof_lanes | type == "array" and all(.[]; type == "string"))'
  jq -e --arg root "$baseline_root" "$shape" "$baseline" >/dev/null || {
    printf 'protected-main migration analysis is incomplete or not of %s\n' "$baseline_root" >&2
    return 1
  }
  jq -e --arg root "$candidate_root" "$shape" "$candidate" >/dev/null || {
    printf 'this head'"'"'s migration analysis is incomplete or not of %s\n' "$candidate_root" >&2
    return 1
  }
  liability="$(jq -er '.liability_score' "$baseline")" || return 1
  lanes="$(jq -c '.required_proof_lanes' "$baseline")" || return 1
  jq -e --argjson baseline "$liability" --argjson lanes "$lanes" '
    .liability_score <= $baseline and
    (.liability_score < $baseline or (($lanes - .required_proof_lanes) | length) == 0)
  ' "$candidate" >/dev/null || {
    printf 'migration liability regressed against protected main (liability %s, lanes %s)\n' \
      "$liability" "$lanes" >&2
    return 1
  }
}

# Print the single integer minimum_score POLICY configures, refusing a policy
# that states it zero times or more than once: a merge floor that depends on
# which duplicate wins is not a floor.
proof_policy_minimum_score() {
  awk -F '=' '
    /^[[:space:]]*minimum_score[[:space:]]*=/ {
      count += 1
      value = $2
      sub(/[[:space:]]*#.*/, "", value)
      gsub(/[[:space:]]/, "", value)
      if (value !~ /^[0-9]+$/) exit 2
      floor = value
    }
    END { if (count != 1) exit 3; print floor }
  ' "$1"
}

# Keep scoring/scan policy byte-identical to protected main. The one exception
# is an explicit transition: AUTHZ (read from the protected-main tree, never from
# the candidate) lists "<protected sha256> <candidate sha256>" lines, and the
# candidate may differ only when both digests of this pair are pinned there.
# Blank lines and #-comments are ignored; any other line shape is refused.
#
# A pin authorizes those exact bytes, not a weaker gate: a pinned transition
# that lowers minimum_score is still refused, so a pin landed for one reason
# cannot be spent on dropping the merge floor.
#
# That numeric floor is the only field this guard compares between the pair.
# hard_findings_allowed, [scan] excluded_paths, [dead_language] allow_terms and
# the required auditor version are authorized by the digests alone, so the
# review that landed the pin is what stands behind them. The rest of the gate is
# unchanged by a pin: both audits still run at main's effective floor, the
# baseline is still protected main's own tree, and the caller still holds this
# head to the auditor's strict ratchet, policy_changed == false included.
proof_require_governed_policy() {
  local candidate="$1" protected="$2" authz="${3:-}" cd_ pd_ line a b cf pf matched
  cmp -s "$candidate" "$protected" && return 0
  if [[ -n "$authz" && -e "$authz" ]]; then
    # Same standard the lane holds the policy files to: a canonical regular
    # file with one link. A pin reached through a symlink is a pin from
    # wherever that link points, which is not the protected-main tree.
    if [[ ! -f "$authz" || -L "$authz" ||
          "$(stat -c '%h' -- "$authz")" != 1 ||
          "$(realpath -- "$authz")" != "$authz" ]]; then
      printf 'policy transition authorization must be a canonical one-link regular file: %s\n' \
        "$authz" >&2
      return 1
    fi
    cd_="$(sha256sum -- "$candidate")" && cd_="${cd_%% *}" || return 1
    pd_="$(sha256sum -- "$protected")" && pd_="${pd_%% *}" || return 1
    # Parse the whole file before honouring any of it: a pin listed above a
    # line nobody can parse must not decide this gate on its own.
    matched=
    while IFS= read -r line || [[ -n "$line" ]]; do
      case "$line" in ''|'#'*) continue ;; esac
      if [[ ! "$line" =~ ^([0-9a-f]{64})[[:space:]]+([0-9a-f]{64})$ ]]; then
        printf 'malformed policy transition authorization line\n' >&2
        return 1
      fi
      a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
      [[ "$a" == "$pd_" && "$b" == "$cd_" ]] && matched=1
    done <"$authz"
    if [[ -n "$matched" ]]; then
      cf="$(proof_policy_minimum_score "$candidate")" || {
        printf 'candidate audit policy must state one integer minimum_score\n' >&2
        return 1
      }
      pf="$(proof_policy_minimum_score "$protected")" || {
        printf 'protected-main audit policy must state one integer minimum_score\n' >&2
        return 1
      }
      if (( cf < pf )); then
        printf 'pinned policy transition lowers the merge floor (%s -> %s)\n' \
          "$pf" "$cf" >&2
        return 1
      fi
      return 0
    fi
  fi
  printf 'candidate audit policy must be byte-identical to protected main unless a digest-pinned transition is authorized\n' >&2
  return 1
}

# Replay a failed security lane's own record (tools/security-lane.sh writes it
# under target/security/) into the attempt log, which outlives the cleanup of
# target/. Each stream is bounded to its last 64 KiB. $1 is the failing status
# of `jankurai security run`; $2 is the target directory, default ./target.
proof_report_security_failure() {
  local rc="${1:-1}" dir="${2:-target}" f
  {
    printf '== security lane failure evidence ==\n'
    printf 'auditor: jankurai security run --script tools/security-lane.sh --strict --profile ci\n'
    printf 'auditor_exit_status=%s\n' "${rc}"
    if [[ -f "${dir}/security/lane.status" ]]; then
      cat -- "${dir}/security/lane.status"
    else
      printf 'wrapper status: not recorded (the wrapper did not finish or did not run)\n'
    fi
    for f in lane.stdout lane.stderr; do
      printf -- '-- %s (last 64 KiB) --\n' "${f}"
      if [[ -f "${dir}/security/${f}" ]]; then
        tail -c 65536 -- "${dir}/security/${f}"
      else
        printf '(absent)\n'
      fi
    done
    if [[ -f "${dir}/jankurai/security/evidence.json" ]]; then
      printf -- '-- auditor evidence.json (first 64 KiB) --\n'
      head -c 65536 -- "${dir}/jankurai/security/evidence.json"
      printf '\n'
    fi
    printf '== end security lane failure evidence ==\n'
  } >&2
}

# A fresh protected-main clone must contain no generated output or other input.
# Keep this pre-digest check separate from the post-audit output allowance.
proof_require_clean_baseline_clone() {
  local repo="$1" base="$2" head inventory
  head="$(git -C "$repo" rev-parse 'HEAD^{commit}')" || return 1
  inventory="$(git -C "$repo" status --porcelain=v1 --untracked-files=all \
    --ignored=traditional)" || return 1
  if [[ "$head" != "$base" || -n "$inventory" ]]; then
    printf 'protected-main baseline clone drifted or is dirty\n' >&2
    return 1
  fi
}

# The baseline full audit writes .jankurai reports (excluded by main's policy)
# and, even with --full --no-score-history, target/jankurai/audit-state.json.
# Enumerate ignored FILES, never collapsed directories, so allowing this one
# state output cannot hide another file under target/. A quoted path refuses.
proof_baseline_untracked_allowed() {
  case "$1" in
    '?? .jankurai/'*|'!! .jankurai/'*) return 0 ;;
    '?? target/jankurai/audit-state.json'|'!! target/jankurai/audit-state.json')
      local repo="$2" path="$2/target/jankurai/audit-state.json"
      [[ -f "$path" && ! -L "$path" &&
         ! -L "$repo/target" && ! -L "$repo/target/jankurai" &&
         "$(stat -c '%h' -- "$path")" == 1 &&
         "$(realpath -- "$path")" == "$path" ]] ;;
    *) return 1 ;;
  esac
}

# Refuse a protected-main baseline clone that this gate changed. The baseline is
# main's bytes: its HEAD must still be the commit the lane checked out, no
# tracked file may be modified, every untracked or ignored path must be the
# baseline audit's own output (proof_baseline_untracked_allowed), and the policy that
# judged this head must hash to DIGEST.
#
# Run before and after audit and after migration: only the named outputs may
# be added to the unchanged tracked tree.
proof_require_protected_baseline() {
  local repo="$1" base="$2" digest="$3" now head tracked untracked entry
  head="$(git -C "$repo" rev-parse 'HEAD^{commit}')" || {
    printf 'cannot read protected-main baseline HEAD\n' >&2
    return 1
  }
  if [[ "$head" != "$base" ]]; then
    printf 'protected-main baseline moved off %s during the gate\n' "$base" >&2
    return 1
  fi
  tracked="$(git -C "$repo" status --porcelain=v1 --untracked-files=no)" || {
    printf 'cannot inspect protected-main baseline tracked files\n' >&2
    return 1
  }
  if [[ -n "$tracked" ]]; then
    printf 'protected-main baseline has modified tracked files\n' >&2
    return 1
  fi
  untracked="$(git -C "$repo" status --porcelain=v1 --untracked-files=all \
    --ignored=traditional)" || {
    printf 'cannot inspect protected-main baseline untracked files\n' >&2
    return 1
  }
  while IFS= read -r entry; do
    case "$entry" in '?? '*|'!! '*) ;; *) continue ;; esac
    proof_baseline_untracked_allowed "$entry" "$repo" || {
      printf 'protected-main baseline holds an unexpected untracked/ignored input: %s\n' \
        "${entry:3}" >&2
      return 1
    }
  done <<<"$untracked"
  now="$(sha256sum -- "$repo/agent/audit-policy.toml")" && now="${now%% *}" || return 1
  if [[ "$now" != "$digest" ]]; then
    printf 'protected-main baseline policy changed during the gate (%s -> %s)\n' \
      "$digest" "$now" >&2
    return 1
  fi
}
