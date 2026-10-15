# Runs the built `claude-sync` against a local directory standing in for the
# rsync remote (rsync accepts plain paths, so no SSH is involved). `claude-sync`
# must be on PATH and built with a `notify-send` that appends its arguments to
# $NOTIFY_LOG (see `checks` in flake.nix).

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  export CLAUDE_SYNC_LOCAL_DIR="$HOME/.claude"
  export CLAUDE_SYNC_REMOTE="$BATS_TEST_TMPDIR/remote"
  export CLAUDE_SYNC_PASSWORD_FILE="$BATS_TEST_TMPDIR/password"
  export CLAUDE_SYNC_PROJECTS=1
  export CLAUDE_SYNC_DIRS="plans memory"
  export CLAUDE_SYNC_FILES="CLAUDE.md"
  export CLAUDE_SYNC_NOTIFY=1
  mkdir -p "$HOME" "$CLAUDE_SYNC_LOCAL_DIR"
  echo secret >"$CLAUDE_SYNC_PASSWORD_FILE"

  export NOTIFY_LOG="$BATS_TEST_TMPDIR/notify.log"

  home_slug="$(printf '%s' "$HOME" | sed -E 's/[^A-Za-z0-9]/-/g')"
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
  [ "$(cat "$CLAUDE_SYNC_REMOTE/plans/p.md")" = plan ]
  [ "$(cat "$CLAUDE_SYNC_REMOTE/memory/m.md")" = mem ]
  [ "$(cat "$CLAUDE_SYNC_REMOTE/CLAUDE.md")" = instructions ]
  [ ! -e "$CLAUDE_SYNC_REMOTE/skills" ]
  [ ! -e "$CLAUDE_SYNC_REMOTE/other.json" ]
}

@test "push maps the \$HOME slug prefix to -HOMESYNC" {
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-app/s.jsonl" home
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-dev-app/s.jsonl" abs

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-app/s.jsonl")" = home ]
  [ "$(cat "$CLAUDE_SYNC_REMOTE/projects/-srv-dev-app/s.jsonl")" = abs ]
}

@test "pull maps -HOMESYNC back to the local \$HOME slug" {
  mkfile "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-app/s.jsonl" home
  mkfile "$CLAUDE_SYNC_REMOTE/projects/-srv-dev-app/s.jsonl" abs

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
  [ -e "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-a/s.jsonl" ]
  [ ! -e "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-b" ]
}

@test "pull with a project dir only syncs that project" {
  mkfile "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-a/s.jsonl" a
  mkfile "$CLAUDE_SYNC_REMOTE/projects/-HOMESYNC-work-b/s.jsonl" b

  run claude-sync pull "$HOME/work/a"
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-a/s.jsonl" ]
  [ ! -e "$CLAUDE_SYNC_LOCAL_DIR/projects/$home_slug-work-b" ]
}

@test "CLAUDE_SYNC_PROJECTS=0 skips projects" {
  CLAUDE_SYNC_PROJECTS=0
  export CLAUDE_SYNC_PROJECTS
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-app/s.jsonl" x
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ "$status" -eq 0 ]
  [ ! -e "$CLAUDE_SYNC_REMOTE/projects" ]
  [ -e "$CLAUDE_SYNC_REMOTE/plans/p.md" ]
}

@test "sync is additive: nothing is ever deleted" {
  mkfile "$CLAUDE_SYNC_REMOTE/plans/remote-only.md" remote
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/local-only.md" local

  run claude-sync push
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_REMOTE/plans/remote-only.md" ]

  run claude-sync pull
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/plans/local-only.md" ]
  [ -e "$CLAUDE_SYNC_LOCAL_DIR/plans/remote-only.md" ]
}

@test "a newer destination file is not overwritten" {
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" old
  touch -d '2020-01-01' "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md"
  mkfile "$CLAUDE_SYNC_REMOTE/plans/p.md" new

  run claude-sync push
  [ "$status" -eq 0 ]
  [ "$(cat "$CLAUDE_SYNC_REMOTE/plans/p.md")" = new ]
}

@test "first push creates a missing nested remote root" {
  CLAUDE_SYNC_REMOTE="$BATS_TEST_TMPDIR/deep/er/remote"
  export CLAUDE_SYNC_REMOTE
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/projects/-srv-app/s.jsonl" x
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ "$status" -eq 0 ]
  [ -e "$CLAUDE_SYNC_REMOTE/projects/-srv-app/s.jsonl" ]
  [ -e "$CLAUDE_SYNC_REMOTE/plans/p.md" ]
}

@test "pull creates a missing local projects/ and dirs" {
  mkfile "$CLAUDE_SYNC_REMOTE/projects/-srv-app/s.jsonl" x
  mkfile "$CLAUDE_SYNC_REMOTE/plans/p.md" plan
  mkfile "$CLAUDE_SYNC_REMOTE/CLAUDE.md" instructions

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
  CLAUDE_SYNC_REMOTE="$BATS_TEST_TMPDIR/file/remote"
  export CLAUDE_SYNC_REMOTE
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  grep -q 'Sync (push, all projects) failed' "$NOTIFY_LOG"
}

@test "a failing sync stays silent when CLAUDE_SYNC_NOTIFY=0" {
  echo x >"$BATS_TEST_TMPDIR/file"
  CLAUDE_SYNC_REMOTE="$BATS_TEST_TMPDIR/file/remote"
  CLAUDE_SYNC_NOTIFY=0
  export CLAUDE_SYNC_REMOTE CLAUDE_SYNC_NOTIFY
  mkfile "$CLAUDE_SYNC_LOCAL_DIR/plans/p.md" plan

  run claude-sync push
  [ ! -e "$NOTIFY_LOG" ]
}
