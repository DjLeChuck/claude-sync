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
        inherit (cfg) remote passwordFile localDir;
      };
      defaultText = lib.literalMD "`claude-sync` built with the options below";
      description = "The claude-sync package to install and run.";
    };

    remote = lib.mkOption {
      type = lib.types.str;
      example = "pcloud-rsync:/claude-code-sync";
      description = ''
        rsync remote root, usually an SSH host alias (defined in your SSH
        config, e.g. `programs.ssh`) followed by a path.
      '';
    };

    passwordFile = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.config/pcloud-rsync-password";
      description = ''
        File holding the SSH password handed to `sshpass -f`. Evaluated by the
        shell at runtime, so it may reference `$HOME`. Never put the secret
        itself here - provision the file separately (e.g. with sops-nix).
      '';
    };

    localDir = lib.mkOption {
      type = lib.types.str;
      default = "$HOME/.claude";
      description = "Local Claude Code directory to sync. May reference `$HOME`.";
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
