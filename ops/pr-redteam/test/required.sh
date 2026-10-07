#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for suite in description quality-gate draft-skip verdict-validation binary-payload credential-transport heartbeat-log model-isolation publication merge-pass poke installation; do
  bash "$here/$suite.sh"
done
