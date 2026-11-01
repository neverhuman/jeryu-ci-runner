#!/bin/sh
# ---------------------------------------------------------------------------
# pr-gate-git-capability.sh -- can this host's Git verify merge-queue replays?
# Queue replay verification in pr-gate-audit.sh uses `git merge-tree --merge-base`, added in Git
# 2.40. The audit refuses a queue job on an older Git at claim time (tool-version error, no score);
# this tells an operator the same thing before installation or any claim. It is read-only, needs no
# site configuration, and changes nothing: ordinary PR admission and proofs are unaffected.
#
# Usage: pr-gate-git-capability.sh [git-version-text]   (default: `git --version`)
# Exit 0: supported. Exit 1: unsupported or unreadable version.
# ---------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then version=$1; else version=$(git --version 2>/dev/null) || version=unavailable; fi
case "$version" in
  "git version "[0-9]*.[0-9]*)
    rest=${version#git version }
    major=${rest%%.*}; rest=${rest#*.}; minor=${rest%%[!0-9]*}
    case "$major$minor" in *[!0-9]*|"") major=x;; esac
    if [ "$major" != x ] && { [ "$major" -gt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -ge 40 ]; }; }; then
      printf 'ok    queue replay verification: %s meets Git >= 2.40\n' "$version"
      exit 0
    fi;;
esac
printf 'FIND  tool-version error: queue replay verification requires Git >= 2.40; found %s\n' "$version"
exit 1
