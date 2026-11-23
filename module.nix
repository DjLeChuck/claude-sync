{ mkClaudeSync }:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.claude-sync;
in
{
  options.services.claude-sync = {
    enable = lib.mkEnableOption "claude-sync and its periodic push safety net";

    package = lib.mkOption {
      type = lib.types.package;
      default = mkClaudeSync pkgs {
        remoteFile = if cfg.remoteFile == null then "" else cfg.remoteFile;
        webdavUser = cfg.webdav.user;
        webdavVendor = cfg.webdav.vendor;
        inherit (cfg)
          backend
          remote
          passwordFile
          localDir
          projects
          directories
          files
          notifyOnFailure
          ;
      };
      defaultText = lib.literalMD "`claude-sync` built with the options below";
      description = "The claude-sync package to install and run.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [
        "rsync"
        "webdav"
      ];
      default = "rsync";
      description = ''
        How to reach the remote: `rsync` (rsync-over-SSH, password
        authentication through `sshpass`) or `webdav` (a WebDAV server such as
        Nextcloud, through rclone).
      '';
    };

    remote = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "https://cloud.example.com/remote.php/dav/files/me/claude-code-sync";
      description = ''
        Remote root. With the `rsync` backend, usually an SSH host alias
        (defined in your SSH config, e.g. `programs.ssh`) followed by a path,
        like `pcloud-rsync:/claude-code-sync`. With the `webdav` backend, the
        URL of the directory to sync into (created on the first push).
        Ignored when `remoteFile` is set.
      '';
    };

    remoteFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/secrets/claude-sync-remote";
      description = ''
        File whose first line is the remote root (same format as `remote`),
        read at runtime. Use it instead of `remote` when the remote must stay
        secret: `remote` ends up in the world-readable Nix store. Evaluated by
        the shell, so it may reference `$HOME`. Provision the file separately
        (e.g. with sops-nix).
      '';
    };

    webdav = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "";
        example = "me";
        description = "WebDAV user name (`webdav` backend only).";
      };

      vendor = lib.mkOption {
        type = lib.types.str;
        default = "nextcloud";
        description = ''
          rclone WebDAV vendor (`webdav` backend only). The server must keep
          files' modification times, which the "only overwrite older files"
          merge relies on: `nextcloud`, `owncloud` and `fastmail` do.
        '';
      };
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.config/pcloud-rsync-password";
      description = ''
        File holding the password: the SSH password handed to `sshpass -f`
        (`rsync` backend), or the WebDAV password (`webdav` backend - with
        Nextcloud, preferably an app password). Evaluated by the shell at
        runtime, so it may reference `$HOME`. Never put the secret itself here -
        provision the file separately (e.g. with sops-nix).
      '';
    };

    localDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.claude";
      description = "Local Claude Code directory to sync. May reference `$HOME`.";
    };

    projects = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Sync `projects/` (conversation history), one project at a time. Project
        slugs are mapped so that `$HOME`-rooted projects merge across machines
        with different usernames.
      '';
    };

    directories = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "plans"
        "memory"
        "skills"
      ];
      description = "Directories of `localDir` to sync (names must not contain spaces).";
    };

    files = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "CLAUDE.md" ];
      example = [
        "CLAUDE.md"
        "keybindings.json"
      ];
      description = "Files of `localDir` to sync (names must not contain spaces).";
    };

    notifyOnFailure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Send a desktop notification (`notify-send`) when a sync fails.
        Failures are always logged to the journal (`journalctl -t claude-sync`).
      '';
    };

    push = {
      onStartupSec = lib.mkOption {
        type = lib.types.str;
        default = "5m";
        description = "Delay after login before the first periodic push.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "3h";
        description = ''
          Interval between periodic pushes. Claude Code's own SessionEnd hook
          already pushes on clean exit; this is the fallback for crashes and
          `kill -9`, where SessionEnd never fires - it bounds how much
          unsynced work a crash can lose.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.remote != "" || cfg.remoteFile != null;
        message = "services.claude-sync: set either `remote` or `remoteFile`.";
      }
    ];

    home.packages = [ cfg.package ];

    systemd.user.services.claude-sync-push = {
      Unit.Description = "Push Claude Code conversations/plans/memory/skills to the sync remote";

      Service = {
        Type = "oneshot";
        ExecStart = "${cfg.package}/bin/claude-sync push";
      };
    };

    systemd.user.timers.claude-sync-push = {
      Unit.Description = "Periodic Claude Code sync safety net";

      Timer = {
        OnStartupSec = cfg.push.onStartupSec;
        OnUnitActiveSec = cfg.push.interval;
      };

      Install.WantedBy = [ "timers.target" ];
    };
  };
}
