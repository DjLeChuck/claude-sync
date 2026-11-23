# claude-sync

Syncs Claude Code conversations, plans, memory and skills (`~/.claude`) between several machines, over rsync-over-SSH or WebDAV (e.g. Nextcloud).

## Why

Claude Code stores everything locally in `~/.claude`. When working on several machines (personal / work), history, plans, memory and skills don't follow. `claude-sync` does an additive merge to/from a remote, through one of two backends:

- `rsync`: rsync-over-SSH, password authentication through `sshpass` (tested with pCloud's rsync gateway);
- `webdav`: a WebDAV server through [rclone](https://rclone.org) (tested with Nextcloud).

What gets synced by default: `projects/`, `plans/`, `memory/`, `skills/` and `CLAUDE.md`. The list is configurable (see below) - e.g. to add `keybindings.json`.

## How it works

- `claude-sync pull [project-dir]` / `claude-sync push [project-dir]`.
- **Additive** merge: `rsync -au` / `rclone copy --update` only overwrite older files and never delete anything (the machines are never used at the same time).
- With `project-dir` (what the `SessionStart`/`SessionEnd` hooks pass, or a path given by hand for an on-demand single-project sync - relative paths like `.` work too), only that project is synced and the configured dirs/files (plans, memory, skills, `CLAUDE.md`, ...) are skipped; without arguments, every project plus all of those is synced.
- **Slug mapping**: Claude Code names `~/.claude/projects/<slug>` after the project's absolute path. Two machines with different usernames would never get the same slug for a `$HOME`-rooted project, so the `$HOME` prefix is replaced with `-HOMESYNC` on the remote side.
- A `flock` (60 s) serializes overlapping syncs. With rsync, all calls of a run share one SSH connection and connection failures are retried with backoff; rclone retries on its own. Once the remote turns out unreachable or refuses the password, the rest of the run is skipped. A real failure is logged (`journalctl -t claude-sync`) and, unless disabled, triggers a desktop notification (`notify-send`).

## Configuration

Environment variables (defaults are baked in when the package is built; an exported variable always wins):

| Variable | Purpose | Package default |
| --- | --- | --- |
| `CLAUDE_SYNC_BACKEND` | `rsync` or `webdav` | `rsync` |
| `CLAUDE_SYNC_REMOTE` | remote root: rsync target, or WebDAV URL of the sync directory | `pcloud-rsync:/claude-code-sync` |
| `CLAUDE_SYNC_REMOTE_FILE` | file whose first line is the remote root, read at runtime (wins over `CLAUDE_SYNC_REMOTE`) - for a remote that must not land in the Nix store | (empty) |
| `CLAUDE_SYNC_PASSWORD_FILE` | file holding the SSH or WebDAV password | `$HOME/.config/pcloud-rsync-password` |
| `CLAUDE_SYNC_WEBDAV_USER` | WebDAV user name (`webdav` only) | (empty) |
| `CLAUDE_SYNC_WEBDAV_VENDOR` | rclone WebDAV vendor (`webdav` only), must keep modification times | `nextcloud` |
| `CLAUDE_SYNC_LOCAL_DIR` | local Claude Code directory | `$HOME/.claude` |
| `CLAUDE_SYNC_PROJECTS` | `1` to sync `projects/`, `0` to skip it | `1` |
| `CLAUDE_SYNC_DIRS` | space-separated directories of the local dir to sync | `plans memory skills` |
| `CLAUDE_SYNC_FILES` | space-separated files of the local dir to sync | `CLAUDE.md` |
| `CLAUDE_SYNC_NOTIFY` | `1` to send a desktop notification on failure, `0` to stay silent | `1` |

Names in `CLAUDE_SYNC_DIRS` / `CLAUDE_SYNC_FILES` must not contain spaces.

With `rsync`, the remote's SSH host (e.g. the `pcloud-rsync` alias) and its host key (`known_hosts`) are yours to configure.

With `webdav`, the remote is the URL of the directory to sync into; it is created on the first push. For Nextcloud: `https://<server>/remote.php/dav/files/<user>/claude-code-sync`, with an app password (Settings → Security) rather than the account password. No rclone configuration is needed.

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
    # Or, through WebDAV (e.g. Nextcloud):
    # backend = "webdav";
    # remote = "https://cloud.example.com/remote.php/dav/files/me/claude-code-sync";
    # webdav.user = "me";
    # webdav.vendor = "nextcloud";
    # remoteFile = "/run/secrets/claude-sync-remote"; # instead of `remote`, to keep it secret
    # passwordFile = "/run/secrets/nextcloud-claude-sync";
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

Or use `inputs.claude-sync.lib.mkClaudeSync pkgs { remote = "..."; files = [ "CLAUDE.md" "keybindings.json" ]; }` to get a package with different defaults (accepted arguments: `backend`, `remote`, `remoteFile`, `passwordFile`, `webdavUser`, `webdavVendor`, `localDir`, `projects`, `directories`, `files`, `notifyOnFailure`).

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
