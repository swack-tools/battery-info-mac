#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: publish_release.sh <asset> [<asset> ...]" >&2
  exit 1
fi

: "${TAG:?TAG is required}"
: "${RELEASE_TITLE:?RELEASE_TITLE is required}"
: "${RELEASE_NOTES_FILE:?RELEASE_NOTES_FILE is required}"

gh_bin="${GH_BIN:-gh}"
release_args=(--title "$RELEASE_TITLE" --notes-file "$RELEASE_NOTES_FILE" --latest)

if [[ -n "${RELEASE_TARGET:-}" ]]; then
  release_args+=(--target "$RELEASE_TARGET")
fi

if "$gh_bin" release view "$TAG" >/dev/null 2>&1; then
  "$gh_bin" release edit "$TAG" "${release_args[@]}"
  "$gh_bin" release upload "$TAG" --clobber "$@"
else
  "$gh_bin" release create "$TAG" "${release_args[@]}" "$@"
fi
