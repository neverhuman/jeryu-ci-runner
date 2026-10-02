#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for suite in quality-gate draft-skip verdict-validation binary-payload credential-transport heartbeat-log model-isolation publication merge-pass installation; do
  bash "$here/$suite.sh"
done
