#!/usr/bin/env bash
# build-bundle.sh — assemble every skill in manifest.tsv into one release tarball.
#
# Runs identically locally and in CI; CI is a thin wrapper around this file so a
# release can never be built by a path that was not tested.
#
#   bash scripts/build-bundle.sh [--version vX.Y.Z] [--outdir DIR] [--keep]
#
# Output: <outdir>/bk-skills-<version>.tar.gz  plus .sha256, and it prints the
# staged tree layout. Nothing is uploaded here; that is the workflow's job.
#
# Each skill is cloned fresh from its public repo. The bundle therefore contains
# a COPY of every skill's .agents/skills/ payload — which is why the resolved
# commit of each clone is recorded in bundle-metadata.txt: without it a bundle
# built from a branch would be unreproducible.
set -euo pipefail

# The script lives in scripts/, but everything it reads is at the repo root.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
MANIFEST="$ROOT/manifest.tsv"
LOADER="$ROOT/skill-config/loader.sh"
VERSION="${BK_SKILLS_VERSION:-}"
OUTDIR="$ROOT/dist"
keep=0

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift ;;
    --outdir)  OUTDIR="$2"; shift ;;
    --keep)    keep=1 ;;
    *) echo "build-bundle: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ -f "$MANIFEST" ] || { echo "build-bundle: no manifest at $MANIFEST" >&2; exit 1; }
[ -f "$LOADER" ]   || { echo "build-bundle: missing shared loader $LOADER" >&2; exit 1; }

if [ -z "$VERSION" ]; then
  # Rolling channel: the bundle is always "latest", rebuilt and re-uploaded on
  # demand. Traceability comes from bundle-metadata.txt (resolved commit per
  # skill, plus this repo's commit and the build time), not from a version number.
  VERSION="latest"
fi

STAGE="$(mktemp -d)"
trap '[ "$keep" = 1 ] || rm -rf "$STAGE"' EXIT
TREE="$STAGE/bk-skills-$VERSION"
mkdir -p "$TREE/skills" "$TREE/skill-config"

say() { printf 'build-bundle: %s\n' "$*"; }

# proxy.sh is this machine's per-command proxy prefix (see AGENTS.md); GitHub
# clones fail here without it. GitHub-hosted runners have no proxy.sh, so the
# same script works in both places by falling back to a direct call.
gitx() { if command -v proxy.sh >/dev/null 2>&1; then proxy.sh git "$@"; else git "$@"; fi; }

# Clone at a branch, tag, or commit. A bare SHA cannot use --branch, and
# --depth 1 --branch is the only cheap way to take a tag or branch, so the two
# cases are handled separately rather than hoping one command fits both.
fetch_one() { # fetch_one <url> <ref> <dest>
  local url="$1" ref="$2" dest="$3"
  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    gitx -C "$dest" -c advice.detachedHead=false fetch --quiet origin "$ref"
    git -C "$dest" -c advice.detachedHead=false checkout --quiet FETCH_HEAD
  else
    gitx clone --quiet --depth 1 --branch "$ref" "$url" "$dest"
  fi
}

count=0
: >"$TREE/bundle-metadata.txt"
while IFS=$'\t' read -r name url ref; do
  case "$name" in ''|\#*) continue ;; esac
  [ -n "$url" ] && [ -n "$ref" ] || { echo "build-bundle: malformed manifest line: $name" >&2; exit 1; }
  work="$STAGE/src/$name"
  mkdir -p "$work"
  if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ ]]; then
    git -C "$work" init -q
    git -C "$work" remote add origin "$url"
  fi
  say "fetching $name ($ref)"
  fetch_one "$url" "$ref" "$work"

  sha="$(git -C "$work" rev-parse HEAD)"
  subject="$(git -C "$work" log -1 --format=%s)"

  # Payload: the skill directories, whatever they are named inside the repo.
  src="$work/.agents/skills"
  [ -d "$src" ] || { echo "build-bundle: $name has no .agents/skills directory" >&2; exit 1; }
  found=0
  for d in "$src"/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    mkdir -p "$TREE/skills/$n"
    # copy the CONTENTS, not the wrapper dir: the install layout is
    # ~/.agents/skills/<name>/SKILL.md
    cp -R "$d." "$TREE/skills/$n/"
    found=$((found+1))
  done
  [ "$found" -gt 0 ] || { echo "build-bundle: $name declares no skill under .agents/skills" >&2; exit 1; }

  {
    printf 'skill\t%s\n' "$name"
    printf 'url\t%s\n' "$url"
    printf 'ref\t%s\n' "$ref"
    printf 'commit\t%s\n' "$sha"
    printf 'subject\t%s\n' "$subject"
    printf 'skills\t%s\n' "$(find "$src" -mindepth 1 -maxdepth 1 -type d -printf '%f ' )"
    printf '\n'
  } >>"$TREE/bundle-metadata.txt"
  count=$((count+1))
done < "$MANIFEST"

[ "$count" -gt 0 ] || { echo "build-bundle: manifest selected nothing" >&2; exit 1; }

# The shared helper the skills require. Ship it beside them, plus its checksum:
# install.sh only checks for existence, so a truncated file must be catchable.
cp -p "$LOADER" "$TREE/skill-config/loader.sh"
( cd "$TREE" && sha256sum skill-config/loader.sh > skill-config/loader.sha256 )

{
  printf 'bundle\tbk-skills-%s\n' "$VERSION"
  printf 'built\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'skills_included\t%s\n' "$count"
  printf 'build_commit\t%s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo not-a-checkout)"
  printf '\n'
} >>"$TREE/bundle-metadata.txt"

mkdir -p "$OUTDIR"
tarball="$OUTDIR/bk-skills-$VERSION.tar.gz"
# Metadata is also copied OUTSIDE the tarball so CI and users can check what a
# release actually contains without extracting it first.
cp "$TREE/bundle-metadata.txt" "$OUTDIR/bundle-metadata.txt"
# Deterministic ordering + no owner/mtime noise, so re-running the same input
# gives the same bytes and a mismatch can only mean a real change.
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="$(git -C "$ROOT" log -1 --format=%cI 2>/dev/null || echo '1970-01-01 00:00:00Z')" \
    -czf "$tarball" -C "$STAGE" "bk-skills-$VERSION"
( cd "$OUTDIR" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256" )

say "built $tarball"
say "contents:"
tar -tzf "$tarball" | sed -n '1,40p' | sed 's/^/  /'
printf '%s\n' "$tarball"
