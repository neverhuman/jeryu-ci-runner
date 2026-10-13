#!/usr/bin/env bash
# pr-gate-steps-report.sh [--all] [--days N] [OWNER/REPO...] — how long each gate step takes, per
# repo, across the attempts this host ran: the numbers for deciding whether a long, low-value step
# should leave the required gate. Reads every attempt's steps.tsv (pr-gate-progress.sh): green
# attempts only unless --all, from the last N days (default 14). Steps sort slowest first by
# median; "share" is the step's part of the median total. Steps group by their key
# (GATE_STEP_KEY_AWK): a temp path, digest or number in the line does not split one step into a row
# per run.
#
#   jeryu/jeryu-web · 12 attempts
#   step                                   median      p90      max  share  runs
#   npm test:e2e:required                   3m10s    3m40s    4m02s    39%    12
set -euo pipefail
case "${1:-}" in -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;; esac
HOME_DIR="${GATE_RUNNER_HOME:-$HOME/gate-runner}"
# shellcheck source=ops/pr-gate/bin/pr-gate-progress.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/pr-gate-progress.sh"
every=0 days=14
repos=()
while (($#)); do
  case "$1" in
    --all) every=1 ;;
    --days) days="${2:?--days needs a number}"; shift ;;
    -*) printf 'unknown option %s\n' "$1" >&2; exit 2 ;;
    *) repos+=("$1") ;;
  esac
  shift
done
[[ "$days" =~ ^[0-9]+$ ]] || { printf -- '--days must be a whole number\n' >&2; exit 2; }

rows=$(mktemp)
trap 'rm -f -- "$rows"' EXIT
while IFS= read -r steps; do
  dir=$(dirname -- "$steps")
  [[ -s "$dir/receipt.json" && -s "$dir/steps.end" ]] || continue
  slug=$(jq -r '"\(.owner)/\(.repo)"' "$dir/receipt.json")
  outcome=$(jq -r '.outcome // ""' "$dir/receipt.json")
  ((every)) || [[ "$outcome" == success ]] || continue
  if ((${#repos[@]})); then
    wanted=0
    for r in "${repos[@]}"; do [[ "$r" == "$slug" ]] && wanted=1; done
    ((wanted)) || continue
  fi
  end=$(cat "$dir/steps.end")
  awk -F'\t' -v slug="$slug" -v end="$end" -v id="$dir" '
    { at[NR] = $1; name[NR] = $2 }
    END { for (i = 1; i <= NR; i++) { t = (i < NR ? at[i + 1] : end) - at[i]; if (t < 0) t = 0
            printf "%s\t%s\t%d\t%s\n", slug, name[i], t, id } }' "$steps" >>"$rows"
done < <(find "$HOME_DIR/attempts" -name steps.tsv -mtime "-$days" 2>/dev/null)

[[ -s "$rows" ]] || { printf 'no attempt with step timings in the last %s days under %s/attempts\n' "$days" "$HOME_DIR"; exit 0; }

LC_ALL=C awk -F'\t' -v OFS='\t' "$GATE_STEP_KEY_AWK"' { $2 = step_key($2); print }' "$rows" |
  sort -t$'\t' -k1,1 -k2,2 -k3,3n | awk -F'\t' '
  function fmt(s) { return s >= 3600 ? sprintf("%dh%02dm", s / 3600, (s % 3600) / 60) : s >= 60 ? sprintf("%dm%02ds", s / 60, s % 60) : sprintf("%ds", s) }
  function flush() {
    if (n == 0) return
    med = v[int((n + 1) / 2)]; p90 = v[int(n * 0.9 + 0.999)]; if (p90 == "") p90 = v[n]
    line[repo, ++count[repo]] = sprintf("%s\t%d\t%d\t%d\t%d", step, med, p90, v[n], n)
    total[repo] += med
    n = 0
  }
  { if ($1 != repo || $2 != step) { flush(); repo = $1; step = $2; repos[repo] = 1 } v[++n] = $3; seen[repo, $4] = 1 }
  END {
    flush()
    for (k in seen) { split(k, part, SUBSEP); attempts[part[1]]++ }
    for (r in repos) {
      printf "%s · %d attempts\n%-44s %8s %8s %8s %6s %5s\n", r, attempts[r], "step", "median", "p90", "max", "share", "runs"
      fflush()
      cmd = "sort -t\"\t\" -k2,2nr"
      for (i = 1; i <= count[r]; i++) print line[r, i] | cmd
      close(cmd)
      printf "%-44s %8s\n\n", "total (sum of medians)", fmt(total[r])
    }
  }' | awk -F'\t' '
  function fmt(s) { return s >= 3600 ? sprintf("%dh%02dm", s / 3600, (s % 3600) / 60) : s >= 60 ? sprintf("%dm%02ds", s / 60, s % 60) : sprintf("%ds", s) }
  NF == 5 { rows[++n] = $0; sum += $2; next }
  { if (n) { for (i = 1; i <= n; i++) { split(rows[i], f, "\t")
                printf "%-44s %8s %8s %8s %5d%% %5d\n", substr(f[1], 1, 44), fmt(f[2]), fmt(f[3]), fmt(f[4]), (sum ? 100 * f[2] / sum : 0), f[5] }
           n = 0; sum = 0 }
    print }
  END { for (i = 1; i <= n; i++) { split(rows[i], f, "\t")
          printf "%-44s %8s %8s %8s %5d%% %5d\n", substr(f[1], 1, 44), fmt(f[2]), fmt(f[3]), fmt(f[4]), (sum ? 100 * f[2] / sum : 0), f[5] } }'
