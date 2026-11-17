#!/usr/bin/env bash
# install-bundle.sh — install every skill from a bk-skills bundle at once.
#
#   bash install-bundle.sh [path/to/bk-skills-vX.Y.Z.tar.gz]
#   bash install-bundle.sh --latest            # fetch the newest release
#
# Installs:
#   bundle skills/*            -> ~/.agents/skills/<name>          (canonical)
#   compatibility symlinks     -> ~/.claude/skills/<name>, ~/.qwen/skills/<name>
#   skill-config/loader.sh     -> ~/.config/skill-config/loader.sh (verified against the shipped sha256)
#
# This is the ONE place that downloads: a bundle is a release artifact, so
# fetching it is the documented purpose. Individual skills never auto-download
# the loader — their install.sh checks for it and tells you to run this script.
set -euo pipefail

DEST="${BK_SKILLS_HOME:-$HOME/.agents/skills}"
LINK_ROOTS=("$HOME/.claude/skills" "$HOME/.qwen/skills")
LOADER_DEST="$HOME/.config/skill-config/loader.sh"
REPO="brucekomike/bk-skills"
LATEST=0
src=""

while [ $# -gt 0 ]; do
  case "$1" in
    --latest) LATEST=1 ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    -*) echo "install-bundle: unknown option: $1" >&2; exit 2 ;;
    *) src="$1" ;;
  esac
  shift
done

say() { printf 'install-bundle: %s\n' "$*"; }

# proxy.sh is this machine's per-command proxy prefix (see AGENTS.md); it is
# optional, so fall back to a direct call when it is not installed.
fetch() { if command -v proxy.sh >/dev/null 2>&1; then proxy.sh "$@"; else "$@"; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ "$LATEST" = 1 ]; then
  command -v gh >/dev/null 2>&1 || { echo "install-bundle: --latest needs the gh CLI, or pass a tarball path" >&2; exit 1; }
  say "resolving latest release of $REPO"
  asset=$(fetch gh release view --repo "$REPO" --json assets --jq '.assets[0].name' 2>/dev/null | tail -1)
  [ -n "$asset" ] && [ "$asset" != "null" ] || { echo "install-bundle: $REPO has no release asset yet" >&2; exit 1; }
  url=$(fetch gh release view --repo "$REPO" --json assets --jq '.assets[0].url' 2>/dev/null | tail -1)
  say "downloading $asset"
  curl -sSL -H 'Authorization: token '"$(fetch gh auth token 2>/dev/null || true)" \
       -o "$TMP/$asset" "$url"
  src="$TMP/$asset"
fi

[ -n "$src" ] || { echo "install-bundle: give a bundle path or --latest" >&2; exit 2; }
[ -f "$src" ] || { echo "install-bundle: no such file: $src" >&2; exit 1; }

root="$(basename "$src" .tar.gz)"
tar -xzf "$src" -C "$TMP"
tree="$TMP/$root"
[ -d "$tree" ] || { echo "install-bundle: unexpected bundle layout (no $root/)" >&2; exit 1; }
[ -d "$tree/skills" ] || { echo "install-bundle: bundle has no skills/ directory" >&2; exit 1; }

echo "=== bundle contents ==="
if [ -f "$tree/bundle-metadata.txt" ]; then
  awk -F'\t' '/^skill/{s=$2} /^ref/{r=$2} /^commit/{printf "  %-22s %-8s %s\n", s, r, substr($2,1,8)}' \
    "$tree/bundle-metadata.txt"
fi

# --- the shared loader, verified before it is placed -------------------------
if [ -f "$tree/skill-config/loader.sh" ]; then
  if [ -f "$tree/skill-config/loader.sha256" ]; then
    # The digest records the path as `skill-config/loader.sh`, relative to the
    # bundle root — so it must be checked FROM the root, not from inside the
    # directory, or the listed file cannot be found and every install fails.
    ( cd "$tree" && sha256sum -c skill-config/loader.sha256 ) \
      || { echo "install-bundle: loader checksum mismatch — refusing to install" >&2; exit 1; }
    say "loader checksum verified"
  else
    say "WARNING: bundle carries no loader.sha256; installing unverified"
  fi
  mkdir -p "$(dirname "$LOADER_DEST")"
  if [ -f "$LOADER_DEST" ]; then
    if cmp -s "$tree/skill-config/loader.sh" "$LOADER_DEST"; then
      say "loader already current: $LOADER_DEST"
    else
      cp -p "$LOADER_DEST" "$LOADER_DEST.bak-$(date +%Y%m%d-%H%M%S)"
      say "kept the previous loader as $LOADER_DEST.bak-*"
      install -m 644 "$tree/skill-config/loader.sh" "$LOADER_DEST"
      say "updated loader"
    fi
  else
    install -m 644 "$tree/skill-config/loader.sh" "$LOADER_DEST"
    say "installed loader -> $LOADER_DEST"
  fi
else
  say "WARNING: this bundle contains no skill-config/loader.sh"
  say "         skills that resolve profiles through the shared loader will not work"
fi

# --- skills ------------------------------------------------------------------
mkdir -p "$DEST"
for skill in "$tree/skills"/*/; do
  [ -d "$skill" ] || continue
  name="$(basename "$skill")"
  if [ ! -f "$skill/SKILL.md" ]; then
    echo "install-bundle: $name has no SKILL.md — skipping rather than half-installing" >&2
    continue
  fi
  # rm -rf before copying: a leftover REAL directory at a link path would make
  # `ln -sfn` nest the new link inside it instead of replacing it.
  rm -rf "${DEST:?}/$name"
  cp -R "$skill" "$DEST/"
  chmod 755 "$DEST/$name/scripts/"*.sh 2>/dev/null || true
  for lr in "${LINK_ROOTS[@]}"; do
    mkdir -p "$lr"
    rm -rf "${lr:?}/$name"
    ln -s "$DEST/$name" "$lr/$name"
  done
  say "installed $name"
done

echo
echo "=== verify ==="
for skill in "$tree/skills"/*/; do
  name="$(basename "$skill")"
  printf '  %-28s canonical:%s claude:%s qwen:%s\n' "$name" \
    "$( [ -f "$DEST/$name/SKILL.md" ] && echo ok || echo MISSING )" \
    "$( [ -f "$HOME/.claude/skills/$name/SKILL.md" ] && echo ok || echo MISSING )" \
    "$( [ -f "$HOME/.qwen/skills/$name/SKILL.md" ] && echo ok || echo MISSING )"
done
printf '  %-28s %s\n' "shared loader" "$( [ -f "$LOADER_DEST" ] && echo ok || echo MISSING )"
echo
say "done. Each skill's own install.sh only checks for the loader; this script is what installs it."
