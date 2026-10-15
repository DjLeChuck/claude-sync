# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`claude-sync` syncs `~/.claude` (projects/conversations, plans, memory, skills, `CLAUDE.md`) between machines using rsync-over-SSH with `sshpass`. It is a single bash script packaged as a Nix flake, plus a home-manager module. See `README.md` for user-facing docs and the config variable table.

There is no test suite and no linter beyond what Nix provides.

## Commands

- Build the package: `nix build` (result in `./result`, git-ignored), then `./result/bin/claude-sync {pull|push} [project-dir]`
- Format Nix files: `nix fmt` (formatter is `nixfmt`)
- Validate the flake: `nix flake check`
- Per the global instructions, also check Nix files with `nixd` diagnostics and `nixfmt`.

`nix build` runs `writeShellApplication`, which applies `shellcheck` at build time. That build is the effective lint for `claude-sync.sh`.

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
- With a `project-dir` argument (passed by the `SessionStart`/`SessionEnd` hooks), only that project is synced. Without it, all projects are synced (manual runs and the timer).
- **Slug mapping**: Claude Code names `projects/<slug>` by replacing every non-alphanumeric character of the project's absolute path with `-`. The local `$HOME` slug prefix is rewritten to `-HOMESYNC` on the remote, and back on pull, so machines with different usernames merge `$HOME`-rooted projects. See `remote_slug_for` / `local_slug_for`.
- Sync is additive only: `rsync -au`, never `--delete`.
- `run_rsync` retries once after 2 s (gateway blips). On a push it first calls `ensure_remote_parents`, which creates missing parents with empty-dir rsyncs instead of `--mkpath` (that needs rsync >= 3.2.3 on the server too).
- A pull first checks that the remote path exists (`pull_exists`), so the first-ever sync is not reported as a failure.
- Real failures are logged with `logger -t claude-sync` and trigger `notify-send` when `CLAUDE_SYNC_NOTIFY=1`.
- Directory and file names in `CLAUDE_SYNC_DIRS` / `CLAUDE_SYNC_FILES` are split on whitespace, so they can't contain spaces.
- `bashOptions = [ ]` in `flake.nix` is deliberate: the script inspects exit codes by hand (`rc=$?`, trailing `cmd && other`), which `set -e` would break. Don't re-enable it.

## Conventions

- Commits follow Conventional Commits (`feat:`, `fix:`, ...), as in the existing history.
- Everything (code, comments, docs, commit messages) is written in English.
- The flake must not use `flake-utils`. It uses `nixpkgs.lib.genAttrs` over a `systems` list instead.
- The package is Linux-only (`flock`, `notify-send`).
