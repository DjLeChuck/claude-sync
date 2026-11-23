# Runs the built `claude-sync` against a remote backed by a local directory,
# $REMOTE_DIR, so tests can seed and inspect it directly:
#   CLAUDE_SYNC_TEST_BACKEND=rsync   (default) rsync accepts plain paths, so no
#                                    SSH is involved
#   CLAUDE_SYNC_TEST_BACKEND=webdav  the directory is served over WebDAV by
#                                    `rclone serve webdav` on 127.0.0.1
# `claude-sync` (and `rclone` for webdav) must be on PATH, `claude-sync` built
# with a `notify-send` that appends its arguments to $NOTIFY_LOG (see `checks`
# in flake.nix).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_SYNC_LOCAL_DIR="$HOME/.claude"
  export CLAUDE_SYNC_PASSWORD_FILE="$BATS_TEST_TMPDIR/password"
  export CLAUDE_SYNC_PROJECTS=1
  export CLAUDE_SYNC_DIRS="plans memory"
  export CLAUDE_SYNC_FILES="CLAUDE.md"
  export CLAUDE_SYNC_NOTIFY=1
  # Keep the retry policy (one retry for session errors, several for connection
  # failures) without actually waiting between attempts.
  export CLAUDE_SYNC_RETRY_DELAYS="0 0 0"
  mkdir -p "$HOME" "$CLAUDE_SYNC_LOCAL_DIR"
  echo secret >"$CLAUDE_SYNC_PASSWORD_FILE"

  export NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"

  home_slug="$(printf '%s' "$HOME" | sed -E 's/[^A-Za-z0-9]/-/g')"

  export CLAUDE_SYNC_BACKEND="${CLAUDE_SYNC_TEST_BACKEND:-rsync}"
  if [ "$CLAUDE_SYNC_BACKEND" = webdav ]; then
    export CLAUDE_SYNC_WEBDAV_USER=test
    # rclone's own WebDAV server keeps modification times the ownCloud way;
    # the nextcloud vendor would also try Nextcloud's chunked-upload endpoint.
    export CLAUDE_SYNC_WEBDAV_VENDOR=owncloud
    # Fail fast instead of going through rclone's retries on purpose-made
    # failures.
    export RCLONE_RETRIES=1 RCLONE_LOW_LEVEL_RETRIES=1
    start_webdav
  fi
  use_remote remote
}

teardown() {
  if [ -n "${webdav_pid:-}" ]; then
    kill "$webdav_pid" 2>/dev/null || true
  fi
}

# Serves $BATS_TEST_TMPDIR over WebDAV on a free local port ($webdav_port).
start_webdav() {
  local try wait
  for try in 1 2 3 4 5; do
    webdav_port=$((20000 + RANDOM % 40000))
    # fd 3 is bats' own: a background process holding it makes bats hang.
    rclone serve webdav "$BATS_TEST_TMPDIR" --addr "127.0.0.1:$webdav_port" -q 3>&- &
    webdav_pid=$!
    for wait in $(seq 50); do
      (exec 4<>"/dev/tcp/127.0.0.1/$webdav_port") 2>/dev/null && return 0
      kill -0 "$webdav_pid" 2>/dev/null || break
      sleep 0.1
    done
    kill "$webdav_pid" 2>/dev/null || true
  done
  echo "could not start rclone serve webdav" >&2
  return 1
}

# Points the remote at $BATS_TEST_TMPDIR/$1 (exposed as $REMOTE_DIR), through
# the backend under test.
use_remote() {
  REMOTE_DIR="$BATS_TEST_TMPDIR/$1"
  case "$CLAUDE_SYNC_BACKEND" in
    rsync) CLAUDE_SYNC_REMOTE="$REMOTE_DIR" ;;
    webdav) CLAUDE_SYNC_REMOTE="http://127.0.0.1:$webdav_port/$1" ;;
  esac
  export REMOTE_DIR CLAUDE_SYNC_REMOTE
}

# Points the remote at a host under the reserved .invalid TLD, which never
# resolves: fails the way an unreachable/refusing remote does, not with the
# backend's "missing path".
use_unreachable_remote() {
  case "$CLAUDE_SYNC_BACKEND" in
    rsync) CLAUDE_SYNC_REMOTE="unreachable.invalid:/remote" ;;
    webdav) CLAUDE_SYNC_REMOTE="http://unreachable.invalid/remote" ;;
  esac
  export CLAUDE_SYNC_REMOTE
}

mkfile() { mkdir -p "$(dirname "$1")" && echo "$2" >"$1"; }

@test "unknown direction prints usage and exits 1" {
  run claude-sync sideways
  [ "$status" -eq 1 ]
  [[ "$output" == *usage* ]]
}

@test "push copies configured dirs and files only" {
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/memory/m.md" mem
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/skills/s.md" skill
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/CLAUDE.md" instructions
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/other.json" other

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$REMOTE_DIR/plans/p.md")" = plan ]
  [ "$(cat "$REMOTE_DIR/memory/m.md")" = mem ]
  [ "$(cat "$REMOTE_DIR/CLAUDE.md")" = instructions ]
  [ ! -e "$REMOTE_DIR/skills" ]
  [ ! -e "$REMOTE_DIR/other.json" ]
}

@test "push maps the \$HOME slug prefix to -HOMESYNC" {
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-app/s.jsonl" home
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-dev-app/s.jsonl" abs

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$REMOTE_DIR/projects/-HOMESYNC-work-app/s.jsonl")" = home ]
  [ "$(cat "$REMOTE_DIR/projects/-srv-dev-app/s.jsonl")" = abs ]
}

@test "pull maps -HOMESYNC back to the local \$HOME slug" {
  mkfile "$REMOTE_DIR/projects/-HOMESYNC-work-app/s.jsonl" home
  mkfile "$REMOTE_DIR/projects/-srv-dev-app/s.jsonl" abs

  run claude-sync pull
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-app/s.jsonl")" = home ]
  [ "$(cat "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-dev-app/s.jsonl")" = abs ]
}

@test "push with a project dir only syncs that project" {
  mkdir -p "$HOME/work/a" "$HOME/work/b"
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" a
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-b/s.jsonl" b

  run claude-sync push "$HOME/work/a"
  [ "$status" -eq 0 ]
  [ -e "$REMOTE_DIR/projects/-HOMESYNC-work-a/s.jsonl" ]
  [ ! -e "$REMOTE_DIR/projects/-HOMESYNC-work-b" ]
}

@test "pull with a project dir only syncs that project" {
  mkfile "$REMOTE_DIR/projects/-HOMESYNC-work-a/s.jsonl" a
  mkfile "$REMOTE_DIR/projects/-HOMESYNC-work-b/s.jsonl" b

  run claude-sync pull "$HOME/work/a"
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" ]
  [ ! -e "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-b" ]
}

@test "a relative project dir (e.g. '.') resolves to the same slug as the absolute path" {
  mkdir -p "$HOME/work/a"
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" a

  cd "$HOME/work/a"
  run claude-sync push .
  [ "$status" -eq 0 ]
  [ -e "$REMOTE_DIR/projects/-HOMESYNC-work-a/s.jsonl" ]
}

@test "push with a project dir skips configured dirs and files" {
  mkdir -p "$HOME/work/a"
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" a
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/CLAUDE.md" instructions

  run claude-sync push "$HOME/work/a"
  [ "$status" -eq 0 ]
  [ -e "$REMOTE_DIR/projects/-HOMESYNC-work-a/s.jsonl" ]
  [ ! -e "$REMOTE_DIR/plans" ]
  [ ! -e "$REMOTE_DIR/CLAUDE.md" ]
}

@test "pull with a project dir skips configured dirs and files" {
  mkfile "$REMOTE_DIR/projects/-HOMESYNC-work-a/s.jsonl" a
  mkfile "$REMOTE_DIR/plans/p.md" plan
  mkfile "$REMOTE_DIR/CLAUDE.md" instructions

  run claude-sync pull "$HOME/work/a"
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" ]
  [ ! -e "$CLAUDE_SYNC_LOCAL_DIR/plans" ]
  [ ! -e "$CLAUDE_SYNC_LOCAL_DIR/CLAUDE.md" ]
}

@test "CLAUDE_SYNC_PROJECTS=0 skips projects" {
  CLAUDE_SYNC_PROJECTS=0
  export CLAUDE_SYNC_PROJECTS
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-app/s.jsonl" x
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ "$status" -eq 0 ]
  [ ! -e "$REMOTE_DIR/projects" ]
  [ -e "$REMOTE_DIR/plans/p.md" ]
}

@test "sync is additive: nothing is ever deleted" {
  mkfile "$REMOTE_DIR/plans/remote-only.md" remote
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/local-only.md" local

  run claude-sync push
  [ "$status" -eq 0 ]
  [ -e "$REMOTE_DIR/plans/remote-only.md" ]

  run claude-sync pull
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/plans/local-only.md" ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/plans/remote-only.md" ]
}

@test "a newer destination file is not overwritten" {
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" old
  touch -d '2020-01-01' "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md"
  mkfile "$REMOTE_DIR/plans/p.md" new

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$REMOTE_DIR/plans/p.md")" = new ]
}

@test "first push creates a missing nested remote root" {
  use_remote deep/er/remote
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-app/s.jsonl" x
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ "$status" -eq 0 ]
  [ -e "$REMOTE_DIR/projects/-srv-app/s.jsonl" ]
  [ -e "$REMOTE_DIR/plans/p.md" ]
}

@test "pull creates a missing local projects/ and dirs" {
  mkfile "$REMOTE_DIR/projects/-srv-app/s.jsonl" x
  mkfile "$REMOTE_DIR/plans/p.md" plan
  mkfile "$REMOTE_DIR/CLAUDE.md" instructions

  run claude-sync pull
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-app/s.jsonl" ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/CLAUDE.md" ]
}

@test "push skips configured items missing locally without failing" {
  # Neither plans/, memory/ nor CLAUDE.md exist locally.
  run claude-sync push
  [ "$status" -eq 0 ]
  [ ! -e "$NOTIFY_LOG" ]
}

@test "pull from an empty remote is not a failure" {
  run claude-sync pull
  [ "$status" -eq 0 ]
  [ ! -e "$NOTIFY_LOG" ]
}

@test "a failing sync notifies when CLAUDE_SYNC_NOTIFY=1" {
  # The remote lives below a regular file, so it can never be created.
  echo x >"$BATS_TEST_TMPDIR/file"
  use_remote file/remote
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  grep -q 'Sync (push, all projects) failed' "$NOTIFY_LOG"
}

@test "a failing sync stays silent when CLAUDE_SYNC_NOTIFY=0" {
  echo x >"$BATS_TEST_TMPDIR/file"
  use_remote file/remote
  CLAUDE_SYNC_NOTIFY=0
  export CLAUDE_SYNC_NOTIFY
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ ! -e "$NOTIFY_LOG" ]
}

@test "a scoped pull from an unreachable remote is reported, not silently skipped" {
  use_unreachable_remote

  run claude-sync pull "$HOME/work/a"
  grep -q 'Sync (pull, a) failed' "$NOTIFY_LOG"
}

@test "a full pull from an unreachable remote is reported, not silently skipped" {
  use_unreachable_remote

  run claude-sync pull
  grep -q 'Sync (pull, all projects) failed' "$NOTIFY_LOG"
}

@test "CLAUDE_SYNC_REMOTE_FILE wins over CLAUDE_SYNC_REMOTE" {
  printf '%s\n' "$CLAUDE_SYNC_REMOTE" >"$BATS_TEST_TMPDIR/remote-file"
  export CLAUDE_SYNC_REMOTE_FILE="$BATS_TEST_TMPDIR/remote-file"
  export CLAUDE_SYNC_REMOTE="$BATS_TEST_TMPDIR/elsewhere"
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$REMOTE_DIR/plans/p.md")" = plan ]
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere" ]
}

@test "a missing remote file fails and notifies" {
  export CLAUDE_SYNC_REMOTE_FILE="$BATS_TEST_TMPDIR/no-such-file"
  export CLAUDE_SYNC_REMOTE=""

  run claude-sync push
  [ "$status" -eq 1 ]
  grep -q 'no remote configured' "$NOTIFY_LOG"
}

@test "webdav: a rate-limited server (429) stops the run after the first failure" {
  [ "$CLAUDE_SYNC_BACKEND" = webdav ] || skip "webdav only"
  # A server answering 429 to everything, logging each request's path.
  cat >"$BATS_TEST_TMPDIR/server.py" <<'PY'
import http.server, sys
log = open(sys.argv[2], "a", buffering=1)
class H(http.server.BaseHTTPRequestHandler):
    def handle_one_request(self):
        self.raw_requestline = self.rfile.readline(65537)
        if not self.raw_requestline or not self.parse_request():
            self.close_connection = True
            return
        log.write(self.command + " " + self.path + "\n")
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(n)
        self.send_response(429)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  local port=$((20000 + RANDOM % 40000))
  python3 "$BATS_TEST_TMPDIR/server.py" "$port" "$BATS_TEST_TMPDIR/requests" 3>&- &
  local server_pid=$!
  for _ in $(seq 50); do
    (exec 4<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && break
    sleep 0.1
  done
  CLAUDE_SYNC_REMOTE="http://127.0.0.1:$port/remote"
  export CLAUDE_SYNC_REMOTE
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-a/s.jsonl" a
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-b/s.jsonl" b

  run claude-sync push
  kill "$server_pid"
  [ "$status" -eq 1 ]
  grep -q 'Sync (push, all projects) failed' "$NOTIFY_LOG"
  # The first project hit the 429; the second one was never attempted.
  grep -q -- '-srv-a' "$BATS_TEST_TMPDIR/requests"
  ! grep -q -- '-srv-b' "$BATS_TEST_TMPDIR/requests"
}
