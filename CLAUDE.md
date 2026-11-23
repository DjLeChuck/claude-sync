# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claude-sync` syncs `~/.claude` (projects/conversations, plans, memory, skills, `CLAUDE.md`) between machines, through one of two backends: rsync-over-SSH with `sshpass`, or WebDAV through rclone. It is a single bash script packaged as a Nix flake, plus a home-manager module. See `README.md` for user-facing docs and the config variable table.

Tests are bats tests in `tests/`, run through `nix flake check`. There is no other linter than what Nix provides.

## Commands

- Build the package: `nix build` (result in `./result`, git-ignored), then `./result/bin/claude-sync {pull|push} [project-dir]`
- Format Nix files: `nix fmt` (formatter is `nixfmt`)
- Run the tests (and validate the flake): `nix flake check --print-build-logs`
- Run a single test: `nix build`, then `PATH=$PWD/result/bin:$PATH nix run nixpkgs#bats -- -f '<name regex>' tests/`. Outside the flake check the real `notify-send` is used, so the two notification tests won't pass there.
- Per the global instructions, also check Nix files with `nixd` diagnostics and `nixfmt`.

`nix build` runs `writeShellApplication`, which applies `shellcheck` at build time. That build is the effective lint for `claude-sync.sh`.

### Test setup

`tests/claude-sync.bats` runs once per backend (`CLAUDE_SYNC_TEST_BACKEND=rsync|webdav`, both runs in the flake check) against a local directory, `$REMOTE_DIR`, that tests seed and inspect directly: rsync accepts local paths (so SSH and `sshpass` are never exercised), and for webdav the directory is served by `rclone serve webdav` on 127.0.0.1 (vendor `owncloud`, which that server supports). Point the remote elsewhere with `use_remote <subdir>` / `use_unreachable_remote`, never by setting `CLAUDE_SYNC_REMOTE` directly. The `checks` output in `flake.nix` builds the package with a fake `libnotify` whose `notify-send` appends to `$NOTIFY_LOG`, since the package puts its own runtime inputs first on `PATH`.

## Architecture

Three files that must be read together:

- `claude-sync.sh`: the actual logic. It is **not** run standalone in practice. `flake.nix` inlines it with `builtins.readFile ./claude-sync.sh` into a `writeShellApplication`.
- `flake.nix`: exposes `lib.mkClaudeSync pkgs { ... }`, `packages.<system>.default` and `homeManagerModules.default`. `mkClaudeSync` prepends `: "${CLAUDE_SYNC_X:=<default>}"` lines to the script, so defaults are baked in at build time and an exported env var still wins at runtime. It also puts the runtime dependencies (rsync, sshpass, openssh, flock via util-linux, libnotify, etc.) on `PATH`.
- `module.nix`: the home-manager module `services.claude-sync`. Its options map one-to-one to `mkClaudeSync` arguments, and it adds a systemd user timer (`claude-sync-push`) as a crash safety net, because the `SessionEnd` hook doesn't fire on a crash or `kill -9`.

### Adding or changing a setting

A new setting has to be wired in four places, which are easy to miss:
1. `claude-sync.sh`: the `: "${CLAUDE_SYNC_X:=...}"` default and its header comment
2. `flake.nix`: the `mkClaudeSync` argument and the baked-in `:=` line (plus the `export` line)
3. `module.nix`: the option, and the `inherit (cfg)` list in the `package` default
4. `README.md`: the configuration table and the module example

### Script behaviors worth knowing

- The script re-execs itself under `flock -w 60 /tmp/claude-code-sync.lock` (guarded by `FLOCKED=1`) so overlapping hook-triggered syncs serialize instead of being dropped.
- With a `project-dir` argument (passed by the `SessionStart`/`SessionEnd` hooks, or given manually for an on-demand single-project sync - resolved through `realpath` first, so a relative path like `.` works too), only that project is synced and `CLAUDE_SYNC_DIRS`/`CLAUDE_SYNC_FILES` are skipped entirely - they have no notion of "this project". Without it, all projects plus the configured dirs/files are synced (manual full runs and the timer).
- **Slug mapping**: Claude Code names `projects/<slug>` by replacing every non-alphanumeric character of the project's absolute path with `-`. The local `$HOME` slug prefix is rewritten to `-HOMESYNC` on the remote, and back on pull, so machines with different usernames merge `$HOME`-rooted projects. See `remote_slug_for` / `local_slug_for`.
- Sync is additive only: `rsync -au` / `rclone copy --update`, never `--delete`. The WebDAV vendor must keep modification times, or `--update` breaks.
- Backend-specific code is confined to `remote_ref`, `transfer`, `remote_exists`, `is_connection_failure`, `should_retry` and the setup block near the top; everything above them (slug mapping, per-project scoping, `sync_item`) is backend-agnostic.
- rsync: all calls of a run share one SSH master connection (`ControlMaster`), closed at the end. SSH connection failures (exit 255) are retried with the `CLAUDE_SYNC_RETRY_DELAYS` backoff; a refused password is never retried; other errors get one retry, after `ensure_remote_parents` on a push (creates missing parents with empty-dir rsyncs instead of `--mkpath`, which needs rsync >= 3.2.3 on the server too).
- webdav: rclone retries on its own, so the script never does. The env vars `RCLONE_WEBDAV_*` configure the on-the-fly `:webdav:` remote (no rclone config file). rclone doesn't create the directory the URL points at, so a push first runs `ensure_webdav_root`.
- Once a connection-level failure (`is_connection_failure`) is logged, `remote_down` makes the rest of the run fail fast.
- A pull first checks that the remote path exists (`remote_exists`), so the first-ever sync is not reported as a failure. Only the backend's "not found" exit code (rsync 23, rclone 3) counts as "not there yet"; any other error is logged and notified like a failed transfer, so a pull against a dead remote is never silent.
- Real failures are logged with `logger -t claude-sync` and trigger `notify-send` when `CLAUDE_SYNC_NOTIFY=1`.
- Directory and file names in `CLAUDE_SYNC_DIRS` / `CLAUDE_SYNC_FILES` are split on whitespace, so they can't contain spaces.
- `bashOptions = [ ]` in `flake.nix` is deliberate: the script inspects exit codes by hand (`rc=$?`, trailing `cmd && other`), which `set -e` would break. Don't re-enable it.

## Conventions

- Commits follow Conventional Commits (`feat:`, `fix:`, ...), as in the existing history.
- Everything (code, comments, docs, commit messages) is written in English.
- The flake must not use `flake-utils`. It uses `nixpkgs.lib.genAttrs` over a `systems` list instead.
- The package is Linux-only (`flock`, `notify-send`).
