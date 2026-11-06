# Releasing

A release is only made from a commit whose CI run (`.github/workflows/ci.yml`) is green on all
six jobs: macOS arm64 and x64, Windows x64 and ARM64, Linux x64 and ARM64.

## Gate

1. Every job passed: install, model download and verification, tests (including the desktop
   end-to-end tests), the Swift tests and app build on macOS, packaging, the package smoke test,
   and (Linux) installing and running the .deb.
2. The macOS release was also exercised on a real Mac with the running services (the CI runners
   have no microphone or desktop user).
3. No secrets or personal files in the commit: no `agent.env`, `bridge.key`, `permissions.json`,
   certificates, `.env.local`, logs, `out/`, `.ci-cache/`, `macos/build/` (all git-ignored) — and
   a scan for tokens and keys came back clean.
4. Docs updated: README, `docs/setup-*.md`, `docs/validation.md` with the run's results.

## Steps

1. Bump `version` in `package.json` (packages are named after it).
2. Push the branch; wait for CI.
3. Download the artifacts from the run (`jarvis-<os>-<arch>`), check them against the
   `SHA256SUMS-*.txt` files.
4. Tag the commit (`v<version>`) and attach the artifacts to a GitHub release, or distribute them
   however you prefer.

## Versioning

Semantic versioning. 0.x: the cross-platform assistant is new; behaviour may still change.
