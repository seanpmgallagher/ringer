#!/bin/bash
# Ringer engine wrapper: run Claude Code CLI under a macOS Seatbelt sandbox.
#
# Claude Code has no OS-level sandbox flag of its own, and headless (-p) runs
# need --dangerously-skip-permissions — whose own help text recommends it only
# inside a sandbox. This wrapper supplies the real containment, mirroring
# opencode-sandboxed.sh: full network and reads, writes confined to the task
# dir, a per-run scratch/cache dir, and Claude's own state paths.
#
# Usage (as a ringer engine bin):
#   claude-sandboxed.sh <taskdir> [--no-sandbox] <claude args...>
#
# The first argument is the task directory (pass "{taskdir}" first in
# args_template). "--no-sandbox" as the second argument skips Seatbelt entirely
# — wire it as the engine's full_access_args so ringer's allow_full_access gate
# still applies. macOS only (sandbox-exec); on other platforms only
# --no-sandbox mode works.
set -euo pipefail

TASKDIR="${1:?usage: claude-sandboxed.sh <taskdir> [--no-sandbox] <args...>}"; shift
SANDBOX=1
if [ "${1:-}" = "--no-sandbox" ]; then SANDBOX=0; shift; fi

# Resolve claude without tripping `set -e` (command -v returns nonzero when absent).
if ! CLAUDE_BIN="$(command -v claude)" || [ -z "$CLAUDE_BIN" ]; then
  echo "claude-sandboxed.sh: claude not found on PATH" >&2
  exit 127
fi

if [ "$SANDBOX" = "0" ]; then
  exec "$CLAUDE_BIN" "$@" < /dev/null
fi

if [ ! -x /usr/bin/sandbox-exec ]; then
  echo "claude-sandboxed.sh: /usr/bin/sandbox-exec not available (macOS only)." >&2
  echo "Use the engine's full-access mode (--no-sandbox) or add your own sandbox." >&2
  exit 1
fi

TASKDIR_REAL="$(cd "$TASKDIR" && pwd -P)"

# Claude Code's node tooling writes to the per-user darwin temp/cache dirs
# (confstr DARWIN_USER_TEMP_DIR/_CACHE_DIR) regardless of TMPDIR — the Bash
# tool EPERM-dies at init without them (probe-verified 2026-07-27). These are
# per-user scratch space, the same allowance codex's workspace-write sandbox
# makes. getconf returns the /var symlinked form; canonicalize for Seatbelt.
DARWIN_TMP="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)"
if [ -n "$DARWIN_TMP" ] && [ -d "$DARWIN_TMP" ]; then
  DARWIN_TMP="$(cd "$DARWIN_TMP" && pwd -P)"
else
  DARWIN_TMP="$TASKDIR_REAL"
fi
DARWIN_CACHE="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
if [ -n "$DARWIN_CACHE" ] && [ -d "$DARWIN_CACHE" ]; then
  DARWIN_CACHE="$(cd "$DARWIN_CACHE" && pwd -P)"
else
  DARWIN_CACHE="$TASKDIR_REAL"
fi

# Claude Code's Bash tool keeps per-project shell state under
# /private/tmp/claude-<uid>/<cwd-with-slashes-as-dashes> (probe-verified
# 2026-07-27: its mkdir there EPERM-killed the Bash tool). Pre-create it and
# allow writes to exactly that subtree — never all of /private/tmp/claude-<uid>,
# which holds other sessions' scratch (including orchestrator check scripts).
CC_TASKTMP="/private/tmp/claude-$(id -u)/${TASKDIR_REAL//\//-}"
mkdir -p "$CC_TASKTMP"

# Per-run scratch root — becomes both TMPDIR and XDG_CACHE_HOME, so we never
# have to open all of /private/tmp or ~/.cache to the sandboxed agent.
# Resolve to the real path (/var/folders symlinks to /private/var/folders);
# Seatbelt subpath matching needs the canonical path or writes EPERM-crash.
SCRATCH="$(cd "$(mktemp -d -t ringer-claude-scratch)" && pwd -P)"
PROFILE="$(mktemp -t ringer-claude-prof)"
cleanup() { rm -rf "$SCRATCH" "$PROFILE"; }
trap cleanup EXIT

# Paths are passed to the profile via sandbox-exec -D parameters, NOT string
# interpolation — a task dir containing quotes/parens/newlines can't inject rules.
# CC_STATE covers ~/.claude (sessions, todos, shell snapshots); CC_JSON covers
# the ~/.claude.json config file and its .backup/.lock siblings via the parent
# $HOME being DENIED except these entries — file literals need their exact paths.
cat > "$PROFILE" <<'SBEOF'
(version 1)
(allow default)
(deny file-write*)
(allow file-write*
  (subpath (param "TASKDIR"))
  (subpath (param "SCRATCH"))
  (subpath (param "CC_STATE"))
  (subpath (param "CC_CACHE"))
  (subpath (param "DARWIN_TMP"))
  (subpath (param "DARWIN_CACHE"))
  (subpath (param "CC_TASKTMP"))
  (literal (param "CC_JSON"))
  (literal (param "CC_JSON_BAK"))
  (literal (param "CC_JSON_LOCK")))
; Claude Code's Bash tool persists a cwd marker at /tmp/claude-<hex>-cwd after
; each command (denied → harmless per-command warning, but cwd tracking breaks
; on multi-command tasks). Only these marker files, nothing else in /tmp.
(allow file-write*
  (regex #"^(/private)?/tmp/claude-[0-9a-f]+-cwd$"))
; /dev is needed for /dev/null, /dev/urandom, etc.; writes there can't create
; persistent files without root, so a few literals are allowed rather than via param.
(allow file-write-data
  (literal "/dev/null")
  (literal "/dev/dtracehelper")
  (literal "/dev/tty"))
SBEOF

export TMPDIR="$SCRATCH"
export XDG_CACHE_HOME="$SCRATCH/cache"
mkdir -p "$XDG_CACHE_HOME"

# Run as a child (not exec) so the EXIT trap fires and cleans up the profile +
# scratch dir even on the success path; propagate the child's exit status.
set +e
/usr/bin/sandbox-exec \
  -D "TASKDIR=$TASKDIR_REAL" \
  -D "SCRATCH=$SCRATCH" \
  -D "CC_STATE=$HOME/.claude" \
  -D "CC_CACHE=$HOME/Library/Caches/claude-cli-nodejs" \
  -D "DARWIN_TMP=$DARWIN_TMP" \
  -D "DARWIN_CACHE=$DARWIN_CACHE" \
  -D "CC_TASKTMP=$CC_TASKTMP" \
  -D "CC_JSON=$HOME/.claude.json" \
  -D "CC_JSON_BAK=$HOME/.claude.json.backup" \
  -D "CC_JSON_LOCK=$HOME/.claude.json.lock" \
  -f "$PROFILE" "$CLAUDE_BIN" "$@" < /dev/null
status=$?
set -e
exit "$status"
