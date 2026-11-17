# ~/.config/skill-config/loader.sh — shared profile loader for agent skills.
#
# Sourced (never executed) by skill scripts. It owns two things that used to be
# duplicated per skill: finding the workspace config, and turning a profile into
# the scalar variables the rest of the script reads.
#
# Config file, one per skill, in the workspace you are standing in:
#
#   <workspace-root>/.config/.deck-skill.sh
#   <workspace-root>/.config/.collective-skill.sh
#   <workspace-root>/.config/.mw-skills.sh
#
# Resolution order, first hit wins:
#   1. $<PREFIX>_CONFIG (or $MW_SKILLS_CONFIG for mw) — explicit file
#   2. nearest .config/.<skill>.sh walking up from $PWD to $HOME
#   3. $PWD/config.sh                       (legacy, kept working)
#   4. ~/.config/<skill>/config.sh          (legacy global, kept working)
#
# Profile format, one array per site — positional, so nothing is retyped:
#
#   DECK_OSSMEDIA=("https://cloud.ossmedia.cn" "brucekomike" "<app-password>")
#   DECK_TJAICC=("https://x" "brucekomike" "<app-password>" "http://127.0.0.1:7897")
#
# Slots: 0 url · 1 username · 2 secret · 3 proxy (optional).
#   `nil` or an absent slot means OFF / not set, for every slot but url.
#   Slot 2 is named TOKEN for deck/collective and PASS for mw — see the tables.
#
# The legacy flat form still loads: DECK_SITE_<NAME>_URL/USER/TOKEN[/PROXY].
# Selected with DECK_SITE=<name> (default: "default", which is the plain
# DECK_URL/USER/TOKEN scalars). Real environment values always beat the file.
#
# This file never prints a secret: sites reporting says set/missing only.
# Nothing here writes anything or runs a network command.

# --- per-skill tables (add a skill = add one line to each) ------------------
declare -gA SKILLCONF_BASENAME=(
  [DECK]="deck-skill"
  [COLLECTIVE]="collective-skill"
  [MW]="mw-skills"
)
# slot -> variable suffix, in positional order
declare -gA SKILLCONF_SLOTS=(
  [DECK]="URL USER TOKEN PROXY"
  [COLLECTIVE]="URL USER TOKEN PROXY"
  [MW]="URL USER PASS PROXY"
)
# scalars that are configuration, never a site name
declare -gA SKILLCONF_RESERVED=(
  [DECK]="URL USER TOKEN PROXY SITE CONFIG"
  [COLLECTIVE]="URL USER TOKEN PROXY SITE CONFIG"
  [MW]="URL USER PASS PROXY SITE SKILLS_CONFIG"
)

# treat literal nil and empty alike: both mean "not set"
_isnil() { [ -z "$1" ] || [ "$1" = "nil" ]; }

# --- resolution --------------------------------------------------------------
# Echoes the config path, or nothing. Sets SKILLCONF_ROOT as a side effect.
skillconf_find() {
  local prefix="$1" base d up lb
  # bash builtins, no subprocess: nothing here forks, which matters because this
  # runs on every invocation of every skill that sources it.
  if [ -n "${SKILLCONF_BASENAME[$prefix]:-}" ]; then
    base="${SKILLCONF_BASENAME[$prefix]}"
  else
    lb="${prefix,,}"; base="${lb//_/-}"
  fi
  local envvar="${prefix}_CONFIG"
  [ "$prefix" = MW ] && envvar="MW_SKILLS_CONFIG"
  local explicit="${!envvar:-}"
  if [ -n "$explicit" ] && [ -f "$explicit" ]; then
    SKILLCONF_ROOT=""; printf '%s\n' "$explicit"; return 0
  fi
  d="$PWD"
  while :; do
    if [ -f "$d/.config/.$base.sh" ]; then
      SKILLCONF_ROOT="$d"; printf '%s\n' "$d/.config/.$base.sh"; return 0
    fi
    [ "$d" = "$HOME" ] && break
    up="$(dirname "$d")"; [ "$up" = "$d" ] && break; d="$up"
  done
  if [ -f "$PWD/config.sh" ]; then SKILLCONF_ROOT=""; printf '%s\n' "$PWD/config.sh"; return 0; fi
  if [ -f "$HOME/.config/$base/config.sh" ]; then SKILLCONF_ROOT=""; printf '%s\n' "$HOME/.config/$base/config.sh"; return 0; fi
  SKILLCONF_ROOT=""; return 1
}

# --- profile application -----------------------------------------------------
# Reads array <PREFIX>_<SITE> (or the legacy flat vars) into <PREFIX>_<slot>.
# $1 prefix, $2 site name. Returns 1 if the site is unknown.
skillconf_apply() {
  # Defaults matter: callers run under `set -u`, so a missing argument must be
  # rejected by the validator below rather than aborting the whole script.
  local prefix="${1:-}" site="${2:-}" key slots arr legacy v i=0 suf out=()
  if [ -z "$prefix" ]; then
    echo "skill-config: skillconf_apply needs a prefix (DECK, COLLECTIVE, MW)" >&2
    return 3
  fi
  # The name is interpolated into an eval below, so it is validated HERE rather
  # than relying on each caller to have checked it.
  if [[ ! "$site" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "skill-config: invalid site name: $site (letters, digits, underscores)" >&2
    return 2
  fi
  key="${site^^}"
  # Callers run under `set -u`; an unknown prefix would abort them on the table
  # lookup below, so it is refused here with its own code.
  if [ -z "${SKILLCONF_SLOTS[$prefix]:-}" ]; then
    echo "skill-config: no slot table for prefix $prefix (known: ${!SKILLCONF_SLOTS[*]})" >&2
    return 3
  fi
  slots="${SKILLCONF_SLOTS[$prefix]}"

  arr="${prefix}_${key}"
  if is_site_array "$arr"; then
    eval 'out=( "${'"$arr"'[@]}" )' || return 1
    if [ "${#out[@]}" -lt 1 ] || _isnil "${out[0]}"; then
      echo "skill-config: $arr has no url in slot 0" >&2; return 1
    fi
    for suf in $slots; do
      v="${out[$i]:-nil}"
      if _isnil "$v"; then unset "${prefix}_${suf}"; else printf -v "${prefix}_${suf}" '%s' "$v"; fi
      i=$((i+1))
    done
    return 0
  fi

  # legacy flat form
  local has=0
  for suf in $slots; do
    legacy="${prefix}_SITE_${key}_${suf}"
    v="${!legacy:-}"
    if [ -n "$v" ]; then printf -v "${prefix}_${suf}" '%s' "$v"; has=1
    else unset "${prefix}_${suf}"; fi
  done
  [ "$has" = 1 ] && return 0
  # A name that matches nothing is the most common failure and was previously
  # silent, which reads as a bug in the loader rather than a typo in the config.
  echo "skill-config: no site '$site' for $prefix (checked $arr and ${prefix}_SITE_${key}_*)" >&2
  local avail; avail="$(skillconf_listsites "$prefix" 2>/dev/null | tr '\n' ' ')"
  [ -n "${avail// /}" ] && echo "skill-config: sites defined: $avail" >&2 \
                        || echo "skill-config: no ${prefix}_<SITE> arrays are defined at all" >&2
  return 1
}

# true only for an INDEXED array: slot order is positional, so scalars and
# associative arrays cannot be sites.
is_site_array() {
  local d
  d="$(declare -p "$1" 2>/dev/null)" || return 1
  case "$d" in "declare -a "*) return 0 ;; *) return 1 ;; esac
}

# Site names are arrays <PREFIX>_<NAME>. A site whose name collides with a
# reserved slot (DECK_TOKEN=, MW_URL= ...) would otherwise vanish silently: the
# owner would be told "unknown site profile" for a site plainly in their file.
skillconf_listsites() {
  local prefix="$1" nm sfx reserved
  reserved=" ${SKILLCONF_RESERVED[$prefix]} "
  while IFS= read -r nm; do
    is_site_array "$nm" || continue
    sfx="${nm#${prefix}_}"
    if case "$reserved" in *" $sfx "*) true ;; *) false ;; esac; then
      echo "skill-config: WARNING: $nm is a site array but '$sfx' is a reserved $prefix slot name; this site is unreachable — rename it." >&2
      continue
    fi
    printf '%s\n' "${sfx,,}"
  done < <(compgen -v "${prefix}_" | sort -u)
}
