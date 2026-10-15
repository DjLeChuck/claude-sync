{
  description = "Sync Claude Code conversations, plans, memory and skills between machines over rsync-over-SSH.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      # flock and notify-send make this Linux-only.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Builds the script with its configuration baked in as overridable
      # defaults (an exported CLAUDE_SYNC_* variable still wins at runtime).
      # `passwordFile` and `localDir` are shell words, so they may reference
      # $HOME.
      mkClaudeSync =
        pkgs:
        {
          remote ? "pcloud-rsync:/claude-code-sync",
          passwordFile ? "$HOME/.config/pcloud-rsync-password",
          localDir ? "$HOME/.claude",
        }:
        pkgs.writeShellApplication {
          name = "claude-sync";
          runtimeInputs = with pkgs; [
            coreutils
            gawk
            gnused
            libnotify
            openssh
            rsync
            sshpass
            util-linux
          ];
          # The script relies on inspecting exit codes by hand (`rc=$?`,
          # `cmd && other` as a last statement), which `set -e` would break.
          bashOptions = [ ];
          text = ''
            : "''${CLAUDE_SYNC_REMOTE:=${remote}}"
            : "''${CLAUDE_SYNC_PASSWORD_FILE:=${passwordFile}}"
            : "''${CLAUDE_SYNC_LOCAL_DIR:=${localDir}}"
            export CLAUDE_SYNC_REMOTE CLAUDE_SYNC_PASSWORD_FILE CLAUDE_SYNC_LOCAL_DIR

            ${builtins.readFile ./claude-sync.sh}
          '';
        };
    in
    {
      lib = { inherit mkClaudeSync; };

      packages = forAllSystems (pkgs: {
        default = mkClaudeSync pkgs { };
      });

      homeManagerModules.default = import ./module.nix { inherit mkClaudeSync; };

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
