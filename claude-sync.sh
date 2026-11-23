# Pushes/pulls the shareable parts of ~/.claude (projects, plus a configurable
# list of directories and files) to/from a remote, through one of two
# backends:
#   rsync   rsync-over-SSH with password authentication (sshpass)
#   webdav  a WebDAV server (e.g. Nextcloud) through rclone
#
# Meant to be wired to Claude Code's SessionStart/SessionEnd hooks plus a
# periodic push timer as a crash safety net. Both backends only overwrite
# older files (`rsync -u` / `rclone --update`) and never delete, since the
# machines are never used at the same time - a plain additive merge.
#
# Configuration (environment, defaults baked in by the Nix package):
#   CLAUDE_SYNC_BACKEND        "rsync" (default) or "webdav"
#   CLAUDE_SYNC_REMOTE         remote root: an rsync target such as
#                              "myhost:/claude-code-sync", or a WebDAV URL such
#                              as "https://cloud.example.com/remote.php/dav/files/me/claude-code-sync"
#   CLAUDE_SYNC_REMOTE_FILE    file whose first line is the remote root, read at
#                              runtime; takes precedence over CLAUDE_SYNC_REMOTE,
#                              for a remote that must stay out of the Nix store
#   CLAUDE_SYNC_PASSWORD_FILE  file holding the password (SSH password for
#                              sshpass, or the WebDAV password - with Nextcloud,
#                              preferably an app password)
#   CLAUDE_SYNC_WEBDAV_USER    WebDAV user name (webdav backend only)
#   CLAUDE_SYNC_WEBDAV_VENDOR  rclone WebDAV vendor (default: "nextcloud"); it
#                              must keep modification times, which `--update`
#                              relies on (nextcloud, owncloud, fastmail, ...)
#   CLAUDE_SYNC_LOCAL_DIR      local Claude Code directory (default: ~/.claude)
#   CLAUDE_SYNC_PROJECTS       "1" to sync projects/ (per-project, see below)
#   CLAUDE_SYNC_DIRS           space-separated directories of LOCAL_DIR to sync
#   CLAUDE_SYNC_FILES          space-separated files of LOCAL_DIR to sync
#                              (names containing spaces are not supported)
#   CLAUDE_SYNC_NOTIFY         "1" to send a desktop notification on failure
#                              (failures are always logged to the journal)
#   CLAUDE_SYNC_RETRY_DELAYS   space-separated waits (seconds) between retries
#                              of an SSH connection failure (rsync backend,
#                              default: "2 5 10 20"); a tuning/testing knob, not
#                              exposed by the module. rclone retries on its own.

: "${CLAUDE_SYNC_BACKEND:=rsync}"
: "${CLAUDE_SYNC_REMOTE:=}"
: "${CLAUDE_SYNC_REMOTE_FILE:=}"
: "${CLAUDE_SYNC_PASSWORD_FILE:?CLAUDE_SYNC_PASSWORD_FILE is not set}"
: "${CLAUDE_SYNC_WEBDAV_USER:=}"
: "${CLAUDE_SYNC_WEBDAV_VENDOR:=nextcloud}"
: "${CLAUDE_SYNC_LOCAL_DIR:=$HOME/.claude}"
: "${CLAUDE_SYNC_PROJECTS:=1}"
: "${CLAUDE_SYNC_DIRS:=}"
: "${CLAUDE_SYNC_FILES:=}"
: "${CLAUDE_SYNC_NOTIFY:=1}"
: "${CLAUDE_SYNC_RETRY_DELAYS=2 5 10 20}"

case "$CLAUDE_SYNC_BACKEND" in
  rsync | webdav) ;;
  *)
    echo "claude-sync: unknown CLAUDE_SYNC_BACKEND '$CLAUDE_SYNC_BACKEND' (expected rsync or webdav)" >&2
    exit 1
    ;;
esac

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
# disk (nor CLAUDE_SYNC_DIRS/FILES), which is what made each session
# start/stop take several seconds. The same scoping is available for a manual
# single-project sync: `claude-sync pull /path/to/project`. Omit it (manual
# full syncs, the push timer) to sync everything.
target_dir="${2:-}"
# The slug is derived from the literal path, so "." or "../foo" would hash to
# something meaningless - resolve to an absolute, canonical path first. `-m`:
# a pull's target_dir legitimately doesn't exist locally yet (nothing to
# canonicalize against), so this must work without requiring anything on disk.
[ -n "$target_dir" ] && target_dir="$(realpath -m "$target_dir")"
remote="$CLAUDE_SYNC_REMOTE"
if [ -n "$CLAUDE_SYNC_REMOTE_FILE" ]; then
  # A missing/unreadable file (e.g. a secret not decrypted yet) leaves $remote
  # empty, reported just below.
  remote="$(head -n 1 "$CLAUDE_SYNC_REMOTE_FILE" 2>/dev/null)"
fi
if [ -z "$remote" ]; then
  # Hooks run detached, so say it where it will be seen, not just on stderr.
  msg="no remote configured (CLAUDE_SYNC_REMOTE is empty, or CLAUDE_SYNC_REMOTE_FILE '$CLAUDE_SYNC_REMOTE_FILE' is missing or empty)"
  echo "claude-sync: $msg" >&2
  printf '%s\n' "$msg" | logger -t claude-sync -p user.err
  [ "$CLAUDE_SYNC_NOTIFY" = 1 ] && notify-send -u critical "Claude Code sync" "Sync failed: no remote configured - journalctl -t claude-sync"
  exit 1
fi
local_dir="$CLAUDE_SYNC_LOCAL_DIR"
backend="$CLAUDE_SYNC_BACKEND"
failed=0
read -ra retry_delays <<<"$CLAUDE_SYNC_RETRY_DELAYS"
# Set once a connection-level failure (remote unreachable, authentication
# refused) survived every retry: the remote is down for this run, so the
# remaining calls fail fast instead of each one going through the whole
# backoff again, hammering the remote and logging the same error dozens of
# times.
remote_down=0

case "$backend" in
  rsync)
    # Every rsync call opens its own SSH session, and a full sync makes one per
    # project. Some gateways (observed with pCloud's) throttle new connections
    # and reset a good share of them during the key exchange. Multiplex them
    # all over a single master connection instead: one TCP connection and one
    # authentication for the whole run. ControlPersist keeps the master alive
    # between calls; it is closed explicitly at the end, and expires on its own
    # if this script dies first.
    ssh_control_path="${XDG_RUNTIME_DIR:-/tmp}/claude-sync-%C"
    ssh_mux_opts=(-o ControlMaster=auto -o "ControlPath=$ssh_control_path" -o ControlPersist=60)
    rsync_ssh="sshpass -f $CLAUDE_SYNC_PASSWORD_FILE ssh ${ssh_mux_opts[*]}"
    ;;
  webdav)
    # rclone's on-the-fly ":webdav:" remote reads its options from these
    # variables - no rclone config file involved, and the password never shows
    # up in a command line. rclone wants it obscured (a reversible encoding,
    # not encryption), and strips the file's trailing newline.
    RCLONE_WEBDAV_URL="$remote"
    RCLONE_WEBDAV_USER="$CLAUDE_SYNC_WEBDAV_USER"
    RCLONE_WEBDAV_VENDOR="$CLAUDE_SYNC_WEBDAV_VENDOR"
    RCLONE_WEBDAV_PASS="$(rclone obscure - <"$CLAUDE_SYNC_PASSWORD_FILE")"
    export RCLONE_WEBDAV_URL RCLONE_WEBDAV_USER RCLONE_WEBDAV_VENDOR RCLONE_WEBDAV_PASS
    ;;
esac

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

# Where relative path $1 (e.g. "projects/<slug>", "CLAUDE.md") lives on the
# remote, in the form the backend's tool expects.
remote_ref() {
  case "$backend" in
    rsync) printf '%s/%s' "$remote" "$1" ;;
    webdav) printf ':webdav:%s' "$1" ;;
  esac
}

# rsync only creates the last level of a destination, so the very first push to
# an empty remote fails on `projects/<slug>` (and on the remote root itself if
# it, or any of its parents, doesn't exist yet). Create every missing ancestor
# of $1 - remote root included - one level at a time, by syncing an empty
# directory onto it. Deliberately not `--mkpath`, which needs rsync >= 3.2.3 on
# the *server* side too. (rclone creates missing parents by itself.)
ensure_remote_parents() {
  local rel host root lead path part empty
  local -a parts
  rel="${1#"$remote"}"
  rel="${rel#/}"
  rel="${rel%/}"
  case "$remote" in
    *:*)
      host="${remote%%:*}:"
      root="${remote#*:}"
      ;;
    *)
      host=""
      root="$remote"
      ;;
  esac
  lead=""
  [ "${root:0:1}" = / ] && lead="/"
  empty="$(mktemp -d)"
  IFS=/ read -ra parts <<<"$root/$rel"
  # The last component is created by the retried rsync itself.
  unset 'parts[-1]'
  path=""
  for part in "${parts[@]}"; do
    [ -n "$part" ] || continue
    path="${path:+$path/}$part"
    rsync -e "$rsync_ssh" -a "$empty/" "$host$lead$path/" >/dev/null 2>&1
  done
  rmdir "$empty"
}

# rclone creates missing parents below the WebDAV URL, but not the directory
# the URL itself points at (nor its ancestors), so the very first push to a
# fresh remote root would fail with "409 Conflict". When the root is missing,
# create it from its closest existing ancestor: try the parent URL first, then
# its parent, and so on - the server's own root is often not a WebDAV
# collection at all (Nextcloud's lives under /remote.php/dav/files/<user>). A
# failure here (e.g. unreachable server) surfaces in the transfers.
ensure_webdav_root() {
  local base="${remote%/}" sub="" rc
  rclone -q lsf --max-depth 1 :webdav: >/dev/null 2>&1
  rc=$?
  # Only a missing root (rclone's "directory not found") needs creating.
  [ "$rc" = 3 ] || return 0
  while [[ "$base" == *://*/* ]]; do
    sub="${base##*/}${sub:+/$sub}"
    base="${base%/*}"
    RCLONE_WEBDAV_URL="$base" rclone -q mkdir ":webdav:$sub" >/dev/null 2>&1 && return 0
  done
  return 0
}

# Whether a call that failed with exit code $1 and output $2 never reached a
# usable session: remote unreachable, connection reset, authentication refused.
# Such a failure means the remote is down for this run (see remote_down).
is_connection_failure() {
  case "$backend" in
    # ssh's own failures exit 255. A refused password goes through sshpass and
    # surfaces as rsync's generic protocol error instead, hence the message.
    rsync) [ "$1" = 255 ] || [[ "$2" == *"Permission denied"* ]] ;;
    # rclone exits 5 on a network error that outlived its own retries, and 1
    # (uncategorised) on an HTTP auth refusal or a rate limit - e.g. Nextcloud's
    # brute-force protection answers 429 to every login from an IP once its
    # delay maxes out, which the rest of the run would only keep hitting.
    webdav)
      [ "$1" = 5 ] ||
        [[ "$2" == *"401 Unauthorized"* ]] ||
        [[ "$2" == *"403 Forbidden"* ]] ||
        [[ "$2" == *"429 Too Many Requests"* ]]
      ;;
  esac
}

# Whether attempt number $3 (0-based) of a call that just failed with exit code
# $1 and output $2 deserves a retry.
#
# rclone already retries on its own (--retries / --low-level-retries), so the
# webdav backend never retries here. For rsync, some gateways (observed with
# pCloud's) reset a sizeable share of SSH connections during the key exchange,
# even isolated ones, so a connection failure gets the whole
# CLAUDE_SYNC_RETRY_DELAYS backoff - except a refused password, which retrying
# won't fix and which could get the account locked out. Any other error comes
# from a session that did open: a single retry, still needed for a first push
# into a remote lacking parent directories.
should_retry() {
  local max=1
  [ "$backend" = rsync ] || return 1
  [[ "$2" == *"Permission denied"* ]] && return 1
  [ "$1" = 255 ] && max=${#retry_delays[@]}
  [ "$3" -lt "$max" ] && [ "$3" -lt "${#retry_delays[@]}" ]
}

# Records a failed call: flags the run as failed and logs the detail. Detached
# hook runs discard stdout/stderr, so the journal is the only place a real
# failure's detail survives - without it, the notification's "check the
# journal" would point at an empty journal.
log_failure() {
  local cmd="$1" rc="$2" attempts="$3" out="$4"
  failed=1
  is_connection_failure "$rc" "$out" && remote_down=1
  printf '%s (exit %s, %s attempts):\n%s\n' "$cmd" "$rc" "$attempts" "$out" | logger -t claude-sync -p user.err
}

# Copies $2 onto $3 (either side may be local or remote, see remote_ref), $1
# being "dir" (copy the directory's contents) or "file".
transfer() {
  local kind="$1" src="$2" dst="$3" out rc attempt=0
  local -a cmd
  if [ "$remote_down" = 1 ]; then
    failed=1
    return
  fi
  case "$backend:$kind" in
    rsync:dir) cmd=(rsync -e "$rsync_ssh" -au "$src/" "$dst/") ;;
    rsync:file) cmd=(rsync -e "$rsync_ssh" -au "$src" "$dst") ;;
    webdav:dir) cmd=(rclone -q copy --update "$src" "$dst") ;;
    webdav:file) cmd=(rclone -q copyto --update "$src" "$dst") ;;
  esac
  # rsync needs a pull's local destination parent to exist (fresh machine, no
  # ~/.claude/projects yet).
  [ "$direction" = pull ] && mkdir -p "$(dirname "$dst")"
  while :; do
    out="$("${cmd[@]}" 2>&1)"
    rc=$?
    [ "$rc" = 0 ] && break
    should_retry "$rc" "$out" "$attempt" || break
    # A session that opened but failed may be a first push into a remote
    # lacking parent directories. Pointless when the connection itself failed.
    [ "$direction" = push ] && ! is_connection_failure "$rc" "$out" && [ "$attempt" = 0 ] && ensure_remote_parents "$dst"
    sleep "${retry_delays[$attempt]}"
    attempt=$((attempt + 1))
  done
  [ "$rc" = 0 ] || log_failure "${cmd[*]}" "$rc" "$((attempt + 1))" "$out"
}

# Pulling a path that doesn't exist yet remotely (first-ever sync, before any
# push happened) is a hard error - check first so that expected case doesn't
# get logged/notified as one. Only the backend's "not found" exit code (rsync:
# 23, rclone: 3) means "not there yet". Anything else - unreachable host,
# refused authentication - is a real failure and must be logged/notified like
# a failed transfer, or a pull against a dead remote would silently do nothing.
#
# $1 is "dir" or "file", $2 a path relative to the remote root. Returns 0 when
# it exists, 1 otherwise. For a directory, the names of its subdirectories are
# left in $remote_subdirs, one per line.
remote_exists() {
  local kind="$1" rel="$2" listing rc attempt=0 missing err_file suffix=""
  local -a cmd
  remote_subdirs=""
  if [ "$remote_down" = 1 ]; then
    failed=1
    return 1
  fi
  case "$backend" in
    rsync)
      # Without the trailing slash, rsync lists the directory entry itself
      # instead of its contents.
      [ "$kind" = dir ] && suffix=/
      cmd=(rsync -e "$rsync_ssh" --list-only "$(remote_ref "$rel")$suffix")
      missing=23
      ;;
    webdav)
      # lsf marks directories with a trailing "/".
      cmd=(rclone -q lsf "$(remote_ref "$rel")")
      missing=3
      ;;
  esac
  err_file="$(mktemp)"
  while :; do
    listing="$("${cmd[@]}" 2>"$err_file")"
    rc=$?
    # A missing path is a definitive answer, only retry real failures.
    { [ "$rc" = 0 ] || [ "$rc" = "$missing" ]; } && break
    should_retry "$rc" "$(cat "$err_file")" "$attempt" || break
    sleep "${retry_delays[$attempt]}"
    attempt=$((attempt + 1))
  done
  if [ "$rc" != 0 ] && [ "$rc" != "$missing" ]; then
    log_failure "${cmd[*]}" "$rc" "$((attempt + 1))" "$(cat "$err_file")"
  fi
  rm -f "$err_file"
  [ "$rc" = 0 ] || return 1
  case "$backend" in
    rsync) remote_subdirs="$(printf '%s\n' "$listing" | awk '$1 ~ /^d/ && $NF != "." {print $NF}')" ;;
    webdav) remote_subdirs="$(printf '%s\n' "$listing" | sed -n 's|/$||p')" ;;
  esac
  return 0
}

# Syncs one item in the current direction: $1 is "dir" or "file", $2 its path
# relative to the remote root, $3 its local path. An item missing locally (no
# CLAUDE.md yet, no skills/ ever created) is nothing to push, not a failure.
sync_item() {
  local kind="$1" rel="$2" local_path="$3"
  case "$direction" in
    push)
      case "$kind" in
        dir) [ -d "$local_path" ] || return 0 ;;
        file) [ -f "$local_path" ] || return 0 ;;
      esac
      transfer "$kind" "$local_path" "$(remote_ref "$rel")"
      ;;
    pull)
      remote_exists "$kind" "$rel" && transfer "$kind" "$(remote_ref "$rel")" "$local_path"
      ;;
  esac
}

# One transfer per project - never a bulk copy of the whole `projects` tree -
# so a hook scoped to $target_dir only pays for listing/comparing its own
# project instead of every project on disk.
sync_projects() {
  local slug d remote_name
  if [ -n "$target_dir" ]; then
    slug="$(raw_slug "$target_dir")"
    sync_item dir "projects/$(remote_slug_for "$slug")" "$local_dir/projects/$slug"
    return
  fi
  case "$direction" in
    push)
      for d in "$local_dir"/projects/*/; do
        [ -d "$d" ] || continue
        slug="$(basename "$d")"
        sync_item dir "projects/$(remote_slug_for "$slug")" "$local_dir/projects/$slug"
      done
      ;;
    pull)
      remote_exists dir projects || return
      while IFS= read -r remote_name; do
        [ -n "$remote_name" ] || continue
        transfer dir "$(remote_ref "projects/$remote_name")" "$local_dir/projects/$(local_slug_for "$remote_name")"
      done <<<"$remote_subdirs"
      ;;
  esac
}

case "$direction" in
  pull | push)
    [ "$direction:$backend" = push:webdav ] && ensure_webdav_root
    [ "$CLAUDE_SYNC_PROJECTS" = 1 ] && sync_projects
    # CLAUDE_SYNC_DIRS/FILES aren't project-scoped (CLAUDE.md, skills, etc. have
    # no notion of "this project"), so a $target_dir call - hook-triggered or a
    # manual single-project sync - only ever touches that one project.
    if [ -z "$target_dir" ]; then
      read -ra sync_dirs <<<"$CLAUDE_SYNC_DIRS"
      read -ra sync_files <<<"$CLAUDE_SYNC_FILES"
      for item in "${sync_dirs[@]}"; do sync_item dir "$item" "$local_dir/$item"; done
      for item in "${sync_files[@]}"; do sync_item file "$item" "$local_dir/$item"; done
    fi
    ;;
  *)
    echo "usage: claude-sync {pull|push} [project-dir]" >&2
    exit 1
    ;;
esac

# Only an SSH remote ("host:path") has a master connection to close.
case "$backend:$remote" in
  rsync:*:*) ssh "${ssh_mux_opts[@]}" -O exit "${remote%%:*}" >/dev/null 2>&1 ;;
esac

if [ "$failed" = 1 ] && [ "$CLAUDE_SYNC_NOTIFY" = 1 ]; then
  if [ -n "$target_dir" ]; then
    label="$(basename "$target_dir")"
  else
    label="all projects"
  fi
  notify-send -u critical "Claude Code sync" "Sync ($direction, $label) failed - journalctl -t claude-sync"
fi

# Hooks ignore it, but a manual run (or a script) can tell a failure apart.
exit "$failed"
