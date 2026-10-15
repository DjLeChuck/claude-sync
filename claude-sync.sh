# Pushes/pulls the shareable parts of ~/.claude (projects, plans, memory,
# skills, CLAUDE.md, statusline.py) to/from a remote reachable through
# rsync-over-SSH with password authentication (sshpass).
#
# Meant to be wired to Claude Code's SessionStart/SessionEnd hooks plus a
# periodic push timer as a crash safety net. `-u` only overwrites older files
# and never deletes, since the machines are never used at the same time - a
# plain additive merge.
#
# Configuration (environment, defaults baked in by the Nix package):
#   CLAUDE_SYNC_REMOTE         rsync remote root, e.g. "myhost:/claude-code-sync"
#   CLAUDE_SYNC_PASSWORD_FILE  file holding the SSH password for sshpass
#   CLAUDE_SYNC_LOCAL_DIR      local Claude Code directory (default: ~/.claude)

: "${CLAUDE_SYNC_REMOTE:?CLAUDE_SYNC_REMOTE is not set}"
: "${CLAUDE_SYNC_PASSWORD_FILE:?CLAUDE_SYNC_PASSWORD_FILE is not set}"
: "${CLAUDE_SYNC_LOCAL_DIR:=$HOME/.claude}"

if [ "${FLOCKED:-}" != "1" ]; then
  # Backgrounded (see the SessionStart/SessionEnd hooks) syncs can overlap -
  # e.g. switching project quickly enough that one session's detached push is
  # still running when the next one's pull starts - so wait for the lock
  # instead of dropping the sync silently on contention.
  exec env FLOCKED=1 flock -w 60 /tmp/claude-code-sync.lock "$0" "$@"
fi

direction="${1:-}"
# Claude Code hooks interpolate ${CLAUDE_PROJECT_DIR} into the hook command
# before running it, so SessionStart/SessionEnd pass their project's directory
# as $2 here and only that one project gets synced - not every project on
# disk, which is what made each session start/stop take several seconds.
# Manual calls and the push timer omit it and get a full sync.
target_dir="${2:-}"
remote="$CLAUDE_SYNC_REMOTE"
local_dir="$CLAUDE_SYNC_LOCAL_DIR"
rsync_ssh="sshpass -f $CLAUDE_SYNC_PASSWORD_FILE ssh"
failed=0

# Claude Code keys ~/.claude/projects/<slug> off a literal transform of the
# project's absolute path (every non-alnum char becomes "-"). Two machines with
# different usernames get a different slug for the same $HOME-rooted project
# and would otherwise never merge. Map the local $HOME prefix to a stable,
# machine-independent one on the remote side, and back on the way in, so any
# $HOME-rooted project - present or future - merges the same way
# non-$HOME-rooted ones already do.
home_slug="$(printf '%s' "$HOME" | sed -E 's/[^A-Za-z0-9]/-/g')"
canonical_slug="-HOMESYNC"

raw_slug() { printf '%s' "$1" | sed -E 's/[^A-Za-z0-9]/-/g'; }

remote_slug_for() {
  case "$1" in
    "$home_slug"-*) printf '%s' "$canonical_slug${1#"$home_slug"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

local_slug_for() {
  case "$1" in
    "$canonical_slug"*) printf '%s' "$home_slug${1#"$canonical_slug"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# rsync only creates the last level of a destination, so the very first push to
# an empty remote fails on `projects/<slug>` (and on the remote root itself if
# it doesn't exist yet). Create every missing ancestor of $1, one level at a
# time, by syncing an empty directory onto it. Deliberately not `--mkpath`,
# which needs rsync >= 3.2.3 on the *server* side too.
ensure_remote_parents() {
  local rel path part empty
  local -a parts
  rel="${1#"$remote"}"
  rel="${rel#/}"
  rel="${rel%/}"
  empty="$(mktemp -d)"
  rsync -e "$rsync_ssh" -a "$empty/" "$remote/" >/dev/null 2>&1
  IFS=/ read -ra parts <<<"$rel"
  # The last component is created by the retried rsync itself.
  unset 'parts[-1]'
  path=""
  for part in "${parts[@]}"; do
    path="$path/$part"
    rsync -e "$rsync_ssh" -a "$empty/" "$remote$path/" >/dev/null 2>&1
  done
  rmdir "$empty"
}

run_rsync() {
  local out rc attempt
  for attempt in 1 2; do
    out="$(rsync -e "$rsync_ssh" -au "$@" 2>&1)"
    rc=$?
    [ "$rc" = 0 ] && break
    # Some rsync gateways (observed with pCloud's) occasionally bounce a
    # session right after accepting it - a transient server-side blip. One
    # quiet retry absorbs it instead of notifying on what a couple of seconds
    # later just works.
    if [ "$attempt" = 1 ]; then
      # Also covers a first push into a remote lacking parent directories.
      [ "$direction" = push ] && ensure_remote_parents "${!#}"
      sleep 2
    fi
  done
  if [ "$rc" != 0 ]; then
    failed=1
    # Detached hook runs discard stdout/stderr, so this is the only place a
    # real failure's detail survives - without it, the notification's "check
    # the journal" would point at an empty journal.
    printf 'rsync %s (exit %s):\n%s\n' "$*" "$rc" "$out" | logger -t claude-sync -p user.err
  fi
}

# A plain rsync pull against a path that doesn't exist yet remotely (first-ever
# sync, before any push happened) is a hard error - check first so that
# expected case doesn't get logged/notified as one. Same retry tolerance as
# run_rsync, for the same transient-bounce reason.
pull_exists() {
  rsync -e "$rsync_ssh" --list-only "$1" >/dev/null 2>&1 && return 0
  sleep 2
  rsync -e "$rsync_ssh" --list-only "$1" >/dev/null 2>&1
}

sync_one() {
  case "$1:$direction" in
    dir:pull) pull_exists "$remote/$2/" && run_rsync "$remote/$2/" "$local_dir/$2/" ;;
    dir:push) run_rsync "$local_dir/$2/" "$remote/$2/" ;;
    file:pull) pull_exists "$remote/$2" && run_rsync "$remote/$2" "$local_dir/$2" ;;
    file:push) run_rsync "$local_dir/$2" "$remote/$2" ;;
  esac
}

# One rsync call per project - never a bulk copy of the whole `projects` tree -
# so a hook scoped to $target_dir only pays for listing/comparing its own
# project instead of every project on disk.
sync_projects() {
  case "$direction" in
    push)
      if [ -n "$target_dir" ]; then
        slug="$(raw_slug "$target_dir")"
        d="$local_dir/projects/$slug"
        [ -d "$d" ] && run_rsync "$d/" "$remote/projects/$(remote_slug_for "$slug")/"
      else
        for d in "$local_dir"/projects/*/; do
          [ -d "$d" ] || continue
          slug="$(basename "$d")"
          run_rsync "$d" "$remote/projects/$(remote_slug_for "$slug")/"
        done
      fi
      ;;
    pull)
      if [ -n "$target_dir" ]; then
        slug="$(raw_slug "$target_dir")"
        remote_path="$remote/projects/$(remote_slug_for "$slug")/"
        pull_exists "$remote_path" && run_rsync "$remote_path" "$local_dir/projects/$slug/"
      else
        while IFS= read -r remote_name; do
          [ -n "$remote_name" ] || continue
          run_rsync "$remote/projects/$remote_name/" "$local_dir/projects/$(local_slug_for "$remote_name")/"
        done < <(rsync -e "$rsync_ssh" --list-only "$remote/projects/" 2>/dev/null | awk '$1 ~ /^d/ && $NF != "." {print $NF}')
      fi
      ;;
  esac
}

case "$direction" in
  pull | push)
    sync_projects
    sync_one dir plans
    sync_one dir memory
    sync_one dir skills
    sync_one file CLAUDE.md
    sync_one file statusline.py
    ;;
  *)
    echo "usage: claude-sync {pull|push} [project-dir]" >&2
    exit 1
    ;;
esac

if [ "$failed" = 1 ]; then
  if [ -n "$target_dir" ]; then
    label="$(basename "$target_dir")"
  else
    label="all projects"
  fi
  notify-send -u critical "Claude Code sync" "Sync ($direction, $label) failed - journalctl -t claude-sync"
fi
