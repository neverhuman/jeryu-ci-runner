#!/usr/bin/env bash
set -euo pipefail
mkdir -p target/artifact-support
cat > target/artifact-support/jeryu-ci-runner.json <<'JSON'
{"schema_version":"jeryu.split.artifact-support/v1","repo":"jeryu-ci-runner","status":"bootstrap"}
JSON
printf 'artifact support bootstrap ok\n'
