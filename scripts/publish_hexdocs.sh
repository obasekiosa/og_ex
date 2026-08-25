#!/usr/bin/env bash
#
# Republishes HexDocs for an already-released OgEx version without creating a
# new package release. Hex packages are immutable, but their documentation is
# not: `mix hex.publish docs` replaces the docs for an existing version.
#
# Usage:
#   scripts/publish_hexdocs.sh <version> [--yes] [--dry-run]
#
# Examples:
#   scripts/publish_hexdocs.sh 0.3.0 --dry-run
#   HEX_API_KEY=... scripts/publish_hexdocs.sh 0.3.0 --yes
#
# The script builds the docs inside a detached git worktree at the version's
# tag (v<version>), so the current working tree and any unreleased changes are
# never published. It copies the current BENCHMARKS.md into the worktree and
# patches the worktree's mix.exs docs extras to include it, because tags
# created before the report existed do not reference it.
#
# Credentials: HEX_API_KEY must be set. When .env exists in the repository
# root and HEX_API_KEY is not already exported, it is sourced automatically.
# The key is never echoed or written anywhere.

set -euo pipefail

version=""
auto_yes=false
dry_run=false

for argument in "$@"; do
  case "$argument" in
    --yes) auto_yes=true ;;
    --dry-run) dry_run=true ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      if [[ -n "$version" ]]; then
        echo "error: unexpected argument '$argument'" >&2
        exit 1
      fi
      version="$argument"
      ;;
  esac
done

if [[ -z "$version" || ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "usage: scripts/publish_hexdocs.sh <version> [--yes] [--dry-run]" >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel)"
tag="v$version"
benchmark_report="$repo_root/BENCHMARKS.md"

if ! git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "error: tag $tag does not exist" >&2
  exit 1
fi

if [[ ! -f "$benchmark_report" ]]; then
  echo "error: $benchmark_report not found in the current checkout" >&2
  exit 1
fi

if [[ -z "${HEX_API_KEY:-}" && -f "$repo_root/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$repo_root/.env"
  set +a
fi

if [[ -z "${HEX_API_KEY:-}" && "$dry_run" == false ]]; then
  echo "error: HEX_API_KEY is not set (add it to .env or export it)" >&2
  exit 1
fi

worktree="$(mktemp -d)/og_ex_hexdocs_$version"
cleanup() {
  git worktree remove --force "$worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "==> creating worktree at $tag"
git worktree add --detach "$worktree" "$tag" >/dev/null

echo "==> copying benchmark report into the worktree"
cp "$benchmark_report" "$worktree/BENCHMARKS.md"

echo "==> patching docs extras in the worktree's mix.exs"
mix_exs="$worktree/mix.exs"

if grep -q '"BENCHMARKS.md"' "$mix_exs"; then
  echo "    extras already reference BENCHMARKS.md; nothing to patch"
else
  # Insert the extra as the first entry of `extras` and add a Benchmarks
  # sidebar group as the first entry of `groups_for_extras`. Anchoring on
  # those two lines works for every release format so far.
  sed -i 's|^      extras: \[$|      extras: [\n        "BENCHMARKS.md",|' "$mix_exs"
  sed -i 's|^      groups_for_extras: \[$|      groups_for_extras: [\n        Benchmarks: ["BENCHMARKS.md"],|' "$mix_exs"

  if ! grep -q '"BENCHMARKS.md"' "$mix_exs"; then
    echo "error: could not patch extras in $mix_exs; inspect the file manually" >&2
    exit 1
  fi
fi

confirm_flag=""
if [[ "$auto_yes" == true ]]; then
  confirm_flag="--yes"
fi

publish_command=(mix hex.publish docs $confirm_flag)

echo "==> fetching dependencies and building docs in the worktree"
(cd "$worktree" && mix deps.get >/dev/null && mix docs >/dev/null)

if [[ "$dry_run" == true ]]; then
  echo "==> dry run: would now execute (in $worktree):"
  echo "    HEX_API_KEY=<redacted> ${publish_command[*]}"
  echo "==> worktree preserved at $worktree for inspection; remove it with:"
  echo "    git worktree remove --force $worktree"
  trap - EXIT
  exit 0
fi

echo "==> publishing docs for $version (package code is not republished)"
# `mix hex.publish docs` can report failure while still exiting zero, so the
# output is inspected instead of trusted.
set +e
publish_output="$(cd "$worktree" && HEX_API_KEY="$HEX_API_KEY" "${publish_command[@]}" 2>&1)"
publish_status=$?
set -e
echo "$publish_output" | tail -n 3

if [[ $publish_status -ne 0 ]] || grep -q "Publishing docs failed" <<<"$publish_output"; then
  echo "error: docs publish failed; hex.pm was not changed. Retry when the" >&2
  echo "network is stable, or run this script from CI." >&2
  exit 1
fi

echo "==> done: https://hexdocs.pm/og_ex/$version"
