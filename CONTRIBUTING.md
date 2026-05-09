# Contributing

## Process

Every change goes through:

1. **Issue** — describe what + acceptance criteria, link to the relevant section in [docs/SPEC.md](docs/SPEC.md)
2. **Branch** — `feat/<short-name>`, `fix/<short-name>`, `chore/<short-name>` from `main`
3. **PR** — link to the issue, fill the checklist
4. **CI green** — `Build` job must pass on `macos-14`
5. **Self-review** — read your own diff before merging
6. **Merge** — squash to `main`

Never push directly to `main` (except the initial Phase 0 bootstrap, which is the bootstrap of this very process).

WIP limit: 2 open PRs at a time.

## Branch naming

- `feat/...` — new feature
- `fix/...` — bug fix
- `chore/...` — tooling, deps, refactor without behavior change
- `docs/...` — documentation only
- `release/v1.x.x` — release prep

## Commit messages

- One-line summary, imperative mood ("Add hotkey picker", not "Added")
- Reference issue with `(#42)` if relevant
- Body explains the why, not the what
- Co-author line for AI assistance

## Build & test locally

```bash
bash scripts/install.sh
```

Builds `.app`, installs to `/Applications/`, launches.

For build-only without install:

```bash
bash scripts/build-app.sh
```

## Changelog

Every PR that changes user-visible behavior must add a line to `CHANGELOG.md` under `[Unreleased]`. Use [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) format.

## Releases

```bash
git tag v1.x.x && git push --tags
```

CI builds, signs ad-hoc, attaches DMG to GitHub Release. Update notifier in the app picks it up within 24h.

## Versioning

[Semantic Versioning](https://semver.org/):
- `MAJOR` — breaking changes to saved data or APIs
- `MINOR` — new features without breaking
- `PATCH` — fixes only
