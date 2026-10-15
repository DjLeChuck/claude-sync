# claude-sync

Syncs Claude Code conversations, plans, memory and skills (`~/.claude`) between several machines over rsync-over-SSH.

## Why

Claude Code stores everything locally in `~/.claude`. When working on several machines (personal / work), history, plans, memory and skills don't follow. `claude-sync` does an additive merge to/from an rsync-over-SSH remote (tested with pCloud's rsync gateway, password authentication through `sshpass`).

What gets synced by default: `projects/`, `plans/`, `memory/`, `skills/` and `CLAUDE.md`. The list is configurable (see below) - e.g. to add `keybindings.json`.

## How it works

- `claude-sync pull [project-dir]` / `claude-sync push [project-dir]`.
- **Additive** merge: `rsync -au` only overwrites older files and never deletes anything (the machines are never used at the same time).
- With `project-dir` (what the `SessionStart`/`SessionEnd` hooks pass), only that project is synced; without arguments, every project is.
- **Slug mapping**: Claude Code names `~/.claude/projects/<slug>` after the project's absolute path. Two machines with different usernames would never get the same slug for a `$HOME`-rooted project, so the `$HOME` prefix is replaced with `-HOMESYNC` on the remote side.
- A `flock` (60 s) serializes overlapping syncs, one quiet retry absorbs transient gateway bounces, and a real failure is logged (`journalctl -t claude-sync`) and, unless disabled, triggers a desktop notification (`notify-send`).

## Configuration

Environment variables (defaults are baked in when the package is built; an exported variable always wins):

| Variable | Purpose | Package default |
| --- | --- | --- |
| `CLAUDE_SYNC_REMOTE` | rsync remote root | `pcloud-rsync:/claude-code-sync` |
| `CLAUDE_SYNC_PASSWORD_FILE` | file holding the SSH password | `$HOME/.config/pcloud-rsync-password` |
| `CLAUDE_SYNC_LOCAL_DIR` | local Claude Code directory | `$HOME/.claude` |
| `CLAUDE_SYNC_PROJECTS` | `1` to sync `projects/`, `0` to skip it | `1` |
| `CLAUDE_SYNC_DIRS` | space-separated directories of the local dir to sync | `plans memory skills` |
| `CLAUDE_SYNC_FILES` | space-separated files of the local dir to sync | `CLAUDE.md` |
| `CLAUDE_SYNC_NOTIFY` | `1` to send a desktop notification on failure, `0` to stay silent | `1` |

Names in `CLAUDE_SYNC_DIRS` / `CLAUDE_SYNC_FILES` must not contain spaces.

The remote's SSH host (e.g. the `pcloud-rsync` alias) and its host key (`known_hosts`) are yours to configure.

## Installation

### home-manager module (recommended)

```nix
inputs.claude-sync = {
  url = "github:DjLeChuck/claude-sync";
  inputs.nixpkgs.follows = "nixpkgs";
};
# ...
home-manager.users.<user> = {
  imports = [ inputs.claude-sync.homeManagerModules.default ];

  services.claude-sync = {
    enable = true;
    remote = "pcloud-rsync:/claude-code-sync";
    passwordFile = "$HOME/.config/pcloud-rsync-password";
    # projects = true;
    # directories = [ "plans" "memory" "skills" ];
    # files = [ "CLAUDE.md" "keybindings.json" ];
    # notifyOnFailure = true;
    # push.interval = "3h";      # safety net if Claude Code crashes
    # push.onStartupSec = "5m";
  };
};
```

The module installs `claude-sync` and a systemd user timer (`claude-sync-push`) that pushes periodically: the `SessionEnd` hook doesn't fire on a crash or `kill -9`, so the timer bounds how much can be lost.

### Package only

```bash
nix profile install "github:DjLeChuck/claude-sync"
```

Or use `inputs.claude-sync.lib.mkClaudeSync pkgs { remote = "..."; files = [ "CLAUDE.md" "keybindings.json" ]; }` to get a package with different defaults (accepted arguments: `remote`, `passwordFile`, `localDir`, `projects`, `directories`, `files`, `notifyOnFailure`).

## Claude Code hooks

In `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [{ "type": "command", "command": "setsid claude-sync pull \"${CLAUDE_PROJECT_DIR}\" < /dev/null > /dev/null 2>&1 &" }] }
    ],
    "SessionEnd": [
      { "hooks": [{ "type": "command", "command": "setsid claude-sync push \"${CLAUDE_PROJECT_DIR}\" < /dev/null > /dev/null 2>&1 &" }] }
    ]
  }
}
```

## Known limitations

- Linux only (`flock`, `notify-send`).
