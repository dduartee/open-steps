#!/usr/bin/env bash
# Shared by both hooks, sourced. They must compute the baseline identically:
# if they ever disagreed, the Stop hook would compare against a baseline it
# cannot reproduce and ask for a report at the start of every session.

OS_MAX_REPOS="${OPEN_STEPS_MAX_REPOS:-25}"

# Session id from a hook payload; constant fallback, never empty. The id comes
# from another program and ends up in the state file, so it is kept only when
# it is a plain identifier. Anything else becomes the fallback.
OS_SESSION_PATTERN='^[A-Za-z0-9._:-]{1,128}$'
os_session_id() { # $1 = raw payload
  local id
  id="$(printf '%s' "${1:-}" \
    | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | head -1 | sed -E 's/.*"([^"]+)"$/\1/')"
  if [[ "$id" =~ $OS_SESSION_PATTERN ]]; then
    OS_SESSION="$id"
  else
    OS_SESSION="nosession"
  fi
}

# The working directory's repository, or every repository one level below it
# (a hub of checkouts). Deeper nesting is not scanned.
os_find_repos() { # sets OS_REPOS, OS_SCOPE
  OS_REPOS=()
  local root sub entry count=0
  if root="$(git rev-parse --show-toplevel 2>/dev/null)" && [ -n "$root" ]; then
    OS_REPOS=("$root")
    OS_SCOPE="$(basename "$root")"
    return 0
  fi
  OS_SCOPE="$(basename "$PWD")"
  for entry in */; do
    [ -e "${entry}.git" ] || continue   # dir or file: worktrees too
    sub="$(git -C "$entry" rev-parse --show-toplevel 2>/dev/null)" || continue
    [ -n "$sub" ] || continue
    OS_REPOS+=("$sub")
    count=$((count + 1))
    [ "$count" -ge "$OS_MAX_REPOS" ] && break
  done
}

# Files this pack writes into the project itself. They are excluded from the
# fingerprint for the same reason reports live outside the repository: writing
# one must never look like work landing, or the map the agent just updated
# asks for a report about itself once the cooldown expires.
OS_SELF_WRITTEN=(':(exclude)BIG-PICTURE.md')

# HEAD plus dirty-file content per repository. Content, not just names:
# `git status --porcelain` alone cannot see a file edited twice.
os_fingerprint() { # sets OS_FINGERPRINT, OS_HEADS, OS_DIRTY, OS_CHANGED
  OS_FINGERPRINT=""; OS_HEADS=""; OS_DIRTY=0; OS_CHANGED=""
  [ "${#OS_REPOS[@]}" -eq 0 ] && return 0
  local parts="" r head dirty n content
  for r in "${OS_REPOS[@]}"; do
    head="$(git -C "$r" rev-parse HEAD 2>/dev/null || echo none)"
    dirty="$(git -C "$r" status --porcelain -- . "${OS_SELF_WRITTEN[@]}" 2>/dev/null || true)"
    n="$(printf '%s' "$dirty" | grep -c . || true)"
    : "${n:=0}"
    content="$(git -C "$r" diff HEAD -- . "${OS_SELF_WRITTEN[@]}" 2>/dev/null || true)"
    parts="$parts|$r:$head:$(printf '%s\n%s' "$dirty" "$content" | cksum | tr -d ' ')"
    OS_DIRTY=$((OS_DIRTY + n))
    [ "$n" -gt 0 ] && OS_CHANGED="$OS_CHANGED $(basename "$r")"
  done
  OS_FINGERPRINT="$(printf '%s' "$parts" | cksum | tr -d ' ')"
  OS_HEADS="$(printf '%s' "$parts" | grep -oE ':[0-9a-f]{40}:' | tr -d '\n')"
}

# Where the reports live. No harness owns this path: the pack used to hardcode
# ~/.claude/open-steps/reports, which was right on Claude Code and merely a
# name everywhere else. Four layers, first match wins:
#
#   1. OPEN_STEPS_REPORTS   explicit override, wins over everything
#   2. .open-steps in the   the project's own answer, committed with it
#      repository root
#   3. ~/.claude/open-steps/reports   a pack that already ran on this machine,
#      read if it holds history, so an upgrade does not orphan past reports
#   4. $XDG_DATA_HOME/open-steps/reports   the default, or ~/.local/share when
#      XDG_DATA_HOME is unset
#
# Layer 3 only applies when the folder has reports in it. Without that test a
# fresh install would adopt an empty leftover directory and ignore XDG forever.
# Every layer ends up absolute: os_expand_path resolves `~` and relative values,
# and a relative XDG_DATA_HOME is refused rather than silently anchored to the
# directory the hook happened to run in.
# The path is printed once per session by session-start.sh, so a skill never
# has to know how it was resolved.
# A configured path is written by a human, so it arrives written for a shell:
# `~/relatorios`, or `reports` meaning "next to the project". File contents get
# no word splitting and no tilde expansion, so those two would otherwise become
# a directory literally named `~` inside the repository, or a reports folder
# committed with the project. Both are normalized here.
os_expand_path() {
  local p="$1" base="$2"
  case "$p" in
    '~')   p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) printf '%s\n' "$p" ;;
    *)  printf '%s\n' "${base%/}/$p" ;;
  esac
}

os_reports_root() {
  if [ -n "${OPEN_STEPS_REPORTS:-}" ]; then
    os_expand_path "$OPEN_STEPS_REPORTS" "$HOME"
    return 0
  fi

  local repo_conf="$HOME/.claude/open-steps/reports"
  local root="${1:-$PWD}"

  if [ -n "$root" ] && [ -f "$root/.open-steps" ]; then
    local configured
    configured="$(sed -n 's/^[[:space:]]*reports[[:space:]]*=[[:space:]]*//p' \
      "$root/.open-steps" 2>/dev/null | head -1)"
    configured="${configured%\"}"; configured="${configured#\"}"
    configured="${configured%\'}"; configured="${configured#\'}"
    if [ -n "$configured" ]; then
      os_expand_path "$configured" "$root"
      return 0
    fi
  fi

  # The old location, but only if it carries history worth keeping.
  if [ -d "$repo_conf" ] && [ -n "$(ls -A "$repo_conf" 2>/dev/null)" ]; then
    printf '%s\n' "$repo_conf"
    return 0
  fi

  # XDG_DATA_HOME set to a relative path is a common mistake, and resolving it
  # against whatever directory the hook happened to run in puts the reports
  # inside the project and moves them whenever the agent changes directory.
  # An absolute check keeps the promise that this path never depends on cwd.
  case "${XDG_DATA_HOME:-$HOME/.local/share}" in
    /*) printf '%s/open-steps/reports\n' "${XDG_DATA_HOME:-$HOME/.local/share}" ;;
    *)  printf '%s/.local/share/open-steps/reports\n' "$HOME" ;;
  esac
}

os_state_paths() { # sets OS_STATE_DIR, OS_REPORT_FILE, OS_STATE_FILE
  OS_REPORTS_ROOT="$(os_reports_root "${OS_REPOS[0]:-$PWD}")"
  OS_STATE_DIR="$OS_REPORTS_ROOT/${OS_SCOPE:-unknown}"
  OS_REPORT_FILE="$OS_STATE_DIR/latest.md"
  OS_STATE_FILE="$OS_STATE_DIR/.stop-state"
}

# Every value in the state file is a session id, a checksum, commit hashes or
# a timestamp, so each one fits this set. The file is read line by line, never
# run as a script, and a value outside the set is ignored. That also covers a
# file written by an older version of these hooks.
OS_STATE_VALUE='^[A-Za-z0-9._:-]*$'

# shellcheck disable=SC2034  # OS_PREV_* are read by the sourcing hook
os_read_state() {
  OS_PREV_SESSION=""; OS_PREV_FINGERPRINT=""; OS_PREV_HEADS=""; OS_PREV_FIRED_AT=0
  [ -f "$OS_STATE_FILE" ] || return 0
  local key value
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ "$value" =~ $OS_STATE_VALUE ]] || continue
    case "$key" in
      OS_STATE_SESSION) OS_PREV_SESSION="$value" ;;
      OS_STATE_FINGERPRINT) OS_PREV_FINGERPRINT="$value" ;;
      OS_STATE_HEADS) OS_PREV_HEADS="$value" ;;
      OS_STATE_FIRED_AT) [[ "$value" =~ ^[0-9]+$ ]] && OS_PREV_FIRED_AT="$value" ;;
    esac
  done 2>/dev/null < "$OS_STATE_FILE"
}

os_state_line() { # $1 = key, $2 = value; a value outside the set is left empty
  if [[ "$2" =~ $OS_STATE_VALUE ]]; then
    printf '%s=%s\n' "$1" "$2"
  else
    printf '%s=\n' "$1"
  fi
}

os_save_state() { # $1 = timestamp of the last report request
  mkdir -p "$OS_STATE_DIR" 2>/dev/null || return 1
  local fired="${1:-0}"
  [[ "$fired" =~ ^[0-9]+$ ]] || fired=0
  {
    os_state_line OS_STATE_SESSION "$OS_SESSION"
    os_state_line OS_STATE_FINGERPRINT "$OS_FINGERPRINT"
    os_state_line OS_STATE_HEADS "$OS_HEADS"
    os_state_line OS_STATE_FIRED_AT "$fired"
  } > "$OS_STATE_FILE"
}
