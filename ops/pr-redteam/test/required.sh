#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
for suite in verdict-validation binary-payload credential-transport model-isolation publication installation; do
  bash "$here/$suite.sh"
done
