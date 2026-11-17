# bk-skills

Builds and ships **one bundle containing every agent skill**, plus the shared
config loader that those skills depend on.

This repo owns two things and nothing else:

1. `skill-config/loader.sh` — the single shared helper (canonical copy).
2. The packaging: CI clones each skill from its own repo and assembles one
   release artifact, so you can install or update the whole set at once.

Each skill keeps its own repository and remains the source of truth for its
code. `manifest.tsv` decides what gets bundled.

## Install everything at once

```bash
bash scripts/install-bundle.sh dist/bk-skills-v0.1.0.tar.gz   # from a checkout
```

or grab the newest published bundle:

```bash
gh release download --repo brucekomike/bk-skills --pattern '*.tar.gz'
bash scripts/install-bundle.sh ./bk-skills-*.tar.gz
```

That places skills in `~/.agents/skills/` (canonical), links them into
`~/.claude/skills` and `~/.qwen/skills` for compatibility, and installs the
shared loader to `~/.config/skill-config/loader.sh` after verifying it against
the checksum shipped inside the bundle.

## The shared loader

Skills that resolve a workspace config (`mission-kickoff`, and the API skills
once they are rewired) source `~/.config/skill-config/loader.sh`. It owns:

- finding `<workspace-root>/.config/.<skill>.sh` by walking up from `$PWD`,
  so a workspace selects itself by being the directory you are in;
- turning one array per site into the scalar variables the scripts read:

```bash
DECK_OSSMEDIA=("https://cloud.ossmedia.cn" "brucekomike" "<app-password>")
DECK_TJAICC=("https://…" "brucekomike" "<app-password>" "http://127.0.0.1:7897")
#   slot 0 url · 1 username · 2 secret · 3 proxy (optional)
```

  An absent slot or the literal `nil` means **off / not set**, so a proxy-less
  site is three entries, not a trailing empty string.
- the legacy flat form (`DECK_SITE_<NAME>_URL/USER/TOKEN`) still loads, so
  existing configs keep working untouched.

Return codes: `0` ok, `1` unknown site (it names the sites that do exist),
`2` invalid site name, `3` unknown prefix or missing argument. Callers run
under `set -euo pipefail`, so every call must be `skillconf_apply … || die`.

A skill's own `install.sh` only **checks** for the loader. If it is missing it
prints how to get it and exits — it never downloads anything by itself:

```
install.sh: shared loader not found at ~/.config/skill-config/loader.sh
            install a bk-skills bundle to get it:
              gh release download --repo brucekomike/bk-skills --pattern '*.tar.gz'
              bash scripts/install-bundle.sh ./bk-skills-*.tar.gz
```

## Releases

Pushing a tag builds and publishes:

```bash
git tag v0.1.0 && git push origin v0.1.0     # workflow publishes the asset
```

The release carries the tarball, its `.sha256`, and `bundle-metadata.txt`
recording the **resolved commit of every skill** — because the manifest tracks
branches, that file is what makes a release reproducible after the fact.

Non-tag events (push, PR, and a nightly cron) build and verify the bundle
without publishing, so a broken skill repo surfaces in CI rather than at
someone's install.

## What is bundled

| Skill | Repo | Status |
| --- | --- | --- |
| deck-skill | [brucekomike/deck-skill](https://github.com/brucekomike/deck-skill) | bundled |
| mw-skills | [brucekomike/mw-skills](https://github.com/brucekomike/mw-skills) | bundled |
| mission-kickoff-skill | [brucekomike/mission-kickoff-skill](https://github.com/brucekomike/mission-kickoff-skill) | bundled |
| collective-skill | [brucekomike/collective-skill](https://github.com/brucekomike/collective-skill) | **excluded from v1** — not fully tested |

`collective-skill` stays installable from its own repo; it is simply not in the
bundle until its Nextcloud Collectives surface has been exercised end to end.

## Layout

```
manifest.tsv                     who gets bundled, and from what ref
skill-config/loader.sh           the shared helper (canonical copy)
scripts/build-bundle.sh          clones + assembles + checksums  (local == CI)
scripts/install-bundle.sh        unpack, place, link, verify
.github/workflows/bundle.yml     build on push/PR/nightly, publish on tag
```

## Building locally

```bash
bash scripts/build-bundle.sh --version v0.1.0
```

On a machine where GitHub needs a proxy, the script prefixes its own git
commands with `proxy.sh` automatically; on runners it calls git directly.
Output lands in `dist/`, which is gitignored.
