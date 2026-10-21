#!/usr/bin/env bash
# Read-only GitHub API for step 3 of nightly.sh: one endpoint, GET only.
#
#   gh-get.sh repos/<owner>/<repo>/compare/release/prod...<sha>
#
# Step 3 reads text mined from transcripts, and an allow rule like
# `Bash(gh api repos/*)` matches only the command's prefix, so flags after the
# endpoint (`-X PUT`, `-f body=…`) would turn a check into a merge or a comment
# on the owner's token (#24 review). This takes exactly one argument, refuses
# anything that looks like a flag, and forces GET.

set -euo pipefail
[ $# -eq 1 ] || { echo "gh-get.sh: exactly one endpoint, got $#" >&2; exit 2; }
case "$1" in
  -*|*[[:space:]]*) echo "gh-get.sh: refusing $1" >&2; exit 2 ;;
esac
exec gh api --method GET -- "$1"
