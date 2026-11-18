#!/usr/bin/env bash
#
# sync-upstream.sh - merge all changes from the upstream project into this fork.
#
# Typical use:
#   ./sync-upstream.sh                  # merge upstream/main into the current branch, then push
#   ./sync-upstream.sh --dry-run        # only show what upstream has that you don't
#   ./sync-upstream.sh --continue       # finish after resolving merge conflicts
#   ./sync-upstream.sh --abort          # undo an interrupted merge/rebase
#
# Options:
#   --dry-run       Fetch and show incoming changes, but change nothing
#   --rebase        Rebase your commits onto upstream instead of merging (force-push)
#   --no-push       Merge/rebase locally but do not push
#   --stash         Auto-stash a dirty working tree and restore it afterwards
#   --continue      Continue an interrupted merge/rebase after resolving conflicts
#   --abort         Abort an interrupted merge/rebase
#   -h, --help      Show this help
#
# Environment overrides:
#   UPSTREAM_REMOTE   remote name for the upstream project (default: upstream)
#   UPSTREAM_BRANCH   upstream branch to sync from           (default: main)
#   PUSH_REMOTE       remote to push the result to           (default: origin)

set -euo pipefail

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
PUSH_REMOTE="${PUSH_REMOTE:-origin}"

DRY_RUN=0
NO_PUSH=0
USE_REBASE=0
USE_STASH=0
CONTINUE=0
ABORT=0

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  BLUE=$'\033[34m'
  RESET=$'\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  RESET=''
fi

info() { printf '%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s==>%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s==>%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%s==>%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./sync-upstream.sh [options]

Fetch the upstream repository and merge its changes into your fork.

Options:
  --dry-run       Fetch and show incoming changes, but make no local changes
  --rebase        Rebase your commits onto upstream instead of merging (force-pushes)
  --no-push       Do not push the result to the push remote
  --stash         Auto-stash a dirty working tree and restore it afterwards
  --continue      Continue a merge/rebase after resolving conflicts
  --abort         Abort an in-progress merge/rebase
  -h, --help      Show this help

Environment overrides:
  UPSTREAM_REMOTE   remote name for the upstream project (default: upstream)
  UPSTREAM_BRANCH   upstream branch to sync from           (default: main)
  PUSH_REMOTE       remote to push the result to           (default: origin)

Examples:
  ./sync-upstream.sh
  ./sync-upstream.sh --dry-run
  UPSTREAM_BRANCH=master ./sync-upstream.sh
EOF
}

while (($# > 0)); do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --no-push)  NO_PUSH=1 ;;
    --rebase)   USE_REBASE=1 ;;
    --stash)    USE_STASH=1 ;;
    --continue) CONTINUE=1 ;;
    --abort)    ABORT=1 ;;
    -h|--help)  usage; exit 0 ;;
    *)          die "Unknown option: $1 (use --help for usage)" ;;
  esac
  shift
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository."
cd "$(git rev-parse --show-toplevel)"

GIT_DIR="$(git rev-parse --git-dir)"
STATE_FILE="$GIT_DIR/sync-upstream-state"

merge_in_progress()  { [[ -f "$GIT_DIR/MERGE_HEAD" ]]; }
rebase_in_progress() { [[ -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" ]]; }
unmerged_files()     { git diff --name-only --diff-filter=U; }

read_state() {
  MODE=""
  STASHED=0
  BACKUP_TAG=""
  if [[ -f "$STATE_FILE" ]]; then
    local key value
    while IFS='=' read -r key value; do
      case "$key" in
        MODE)    MODE="$value" ;;
        STASHED) STASHED="$value" ;;
        BACKUP)  BACKUP_TAG="$value" ;;
        NOPUSH)  if [[ "$value" == "1" ]]; then NO_PUSH=1; fi ;;
      esac
    done < "$STATE_FILE"
  fi
}

write_state() {
  local mode="$1" stashed="$2" backup="$3"
  {
    printf 'MODE=%s\n' "$mode"
    printf 'STASHED=%s\n' "$stashed"
    printf 'BACKUP=%s\n' "$backup"
    printf 'NOPUSH=%s\n' "$NO_PUSH"
  } > "$STATE_FILE"
}

restore_stash() {
  local stashed="${1:-0}"
  if [[ "$stashed" == "1" ]]; then
    info "Restoring auto-stashed working tree changes..."
    if git stash pop --quiet; then
      ok "Working tree changes restored."
    else
      warn "Could not cleanly restore the auto-stashed changes."
      warn "They are still available via 'git stash list' and 'git stash pop'."
    fi
  fi
}

push_result() {
  local mode="${1:-merge}"
  local branch

  if (( NO_PUSH )); then
    info "Skipping push (--no-push). Push manually when you are ready."
    return 0
  fi

  if ! git remote get-url "$PUSH_REMOTE" >/dev/null 2>&1; then
    warn "Remote '$PUSH_REMOTE' is not configured; skipping push."
    return 0
  fi

  branch="$(git rev-parse --abbrev-ref HEAD)"
  if [[ "$branch" == "HEAD" ]]; then
    warn "Detached HEAD; skipping push."
    return 0
  fi

  info "Pushing '$branch' to '$PUSH_REMOTE'..."
  if [[ "$mode" == "rebase" ]]; then
    git push --force-with-lease "$PUSH_REMOTE" "HEAD:refs/heads/$branch"
  else
    git push "$PUSH_REMOTE" "HEAD:refs/heads/$branch"
  fi
  ok "Pushed to $PUSH_REMOTE/$branch."
}

print_conflict_help() {
  local mode="$1"
  local backup="$2"
  local conflicts

  conflicts="$(unmerged_files || true)"

  printf '\n' >&2
  warn "$mode stopped because of conflicts."
  if [[ -n "$conflicts" ]]; then
    printf 'Conflicted files:\n' >&2
    while IFS= read -r file; do
      printf '    %s\n' "$file" >&2
    done <<< "$conflicts"
  fi

  cat >&2 <<EOF

Next steps:
  1. Edit the conflicted files and stage the resolutions:
         git add <resolved-files>
  2. Finish the $mode:
         ./sync-upstream.sh --continue

To undo everything instead:
         ./sync-upstream.sh --abort

A safety backup of your branch before this sync is at:
         ${backup:-<none>}
EOF
}

# ---------------------------------------------------------------------------
# --abort: undo an interrupted merge/rebase
# ---------------------------------------------------------------------------
if (( ABORT )); then
  if rebase_in_progress; then
    git rebase --abort
    rm -f "$STATE_FILE"
    ok "Rebase aborted; the branch is back to its previous state."
  elif merge_in_progress; then
    git merge --abort
    rm -f "$STATE_FILE"
    ok "Merge aborted; the branch is back to its previous state."
  else
    rm -f "$STATE_FILE"
    warn "No merge or rebase is in progress."
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# --continue: finish a merge/rebase after conflicts were resolved
# ---------------------------------------------------------------------------
if (( CONTINUE )); then
  read_state

  if merge_in_progress; then
    MODE="${MODE:-merge}"
    if [[ -n "$(unmerged_files)" ]]; then
      warn "Conflicts are still unresolved:"
      while IFS= read -r file; do
        printf '    %s\n' "$file" >&2
      done < <(unmerged_files)
      die "Resolve them, 'git add' the files, then run --continue again."
    fi
    git commit --no-edit
    ok "Merge commit created."
  elif rebase_in_progress; then
    MODE="${MODE:-rebase}"
    if [[ -n "$(unmerged_files)" ]]; then
      warn "Conflicts are still unresolved:"
      while IFS= read -r file; do
        printf '    %s\n' "$file" >&2
      done < <(unmerged_files)
      die "Resolve them, 'git add' the files, then run --continue again."
    fi
    if ! GIT_EDITOR=true git rebase --continue; then
      print_conflict_help "rebase" "${BACKUP_TAG:-}"
      exit 1
    fi
    ok "Rebase completed."
  else
    rm -f "$STATE_FILE"
    die "No merge or rebase is in progress; nothing to continue."
  fi

  push_result "$MODE"
  restore_stash "$STASHED"
  rm -f "$STATE_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# Normal sync
# ---------------------------------------------------------------------------
git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1 \
  || die "Remote '$UPSTREAM_REMOTE' is not configured. Add it with: git remote add $UPSTREAM_REMOTE <upstream-repo-url>"

if merge_in_progress || rebase_in_progress; then
  die "A merge/rebase is already in progress. Resolve it and use --continue, or use --abort."
fi

info "Fetching '$UPSTREAM_REMOTE' (including tags)..."
git fetch --prune --tags "$UPSTREAM_REMOTE"

UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
git rev-parse --verify --quiet "$UPSTREAM_REF" >/dev/null \
  || die "Branch '$UPSTREAM_BRANCH' not found on remote '$UPSTREAM_REMOTE'."

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "HEAD" ]] && die "You are on a detached HEAD; check out a branch first."

MERGE_BASE="$(git merge-base HEAD "$UPSTREAM_REF" 2>/dev/null || true)"
INCOMING="$(git rev-list --count "HEAD..$UPSTREAM_REF")"

if (( INCOMING == 0 )); then
  ok "Already up to date: '$UPSTREAM_REF' has no commits missing from '$BRANCH'."
  exit 0
fi

info "Upstream has $INCOMING commit(s) not in '$BRANCH':"
git --no-pager log --oneline --decorate --no-merges "HEAD..$UPSTREAM_REF" | sed 's/^/    /'
echo
info "Files changed upstream since the fork point:"
if [[ -n "$MERGE_BASE" ]]; then
  git --no-pager diff --stat "HEAD...$UPSTREAM_REF" | sed 's/^/    /'
else
  warn "No common history with '$UPSTREAM_REF' (unrelated histories)."
  git --no-pager diff --stat "$UPSTREAM_REF" | sed 's/^/    /'
fi
echo

if (( DRY_RUN )); then
  info "Dry run: nothing was merged or pushed."
  exit 0
fi

STASHED=0
if [[ -n "$(git status --porcelain)" ]]; then
  if (( USE_STASH )); then
    info "Stashing working tree changes..."
    git stash push --include-untracked -m "sync-upstream auto-stash $(date '+%Y-%m-%d %H:%M:%S')"
    STASHED=1
  else
    die "Working tree is not clean. Commit or stash your changes, or rerun with --stash."
  fi
fi

BACKUP_TAG="backup/pre-upstream-sync-$(date '+%Y%m%d-%H%M%S')"
git tag "$BACKUP_TAG" HEAD
info "Safety backup tag created: $BACKUP_TAG"

if (( USE_REBASE )); then
  write_state "rebase" "$STASHED" "$BACKUP_TAG"
  info "Rebasing '$BRANCH' onto '$UPSTREAM_REF'..."
  if git rebase "$UPSTREAM_REF"; then
    ok "Rebase completed."
  else
    print_conflict_help "rebase" "$BACKUP_TAG"
    exit 1
  fi
  MODE="rebase"
else
  write_state "merge" "$STASHED" "$BACKUP_TAG"
  info "Merging '$UPSTREAM_REF' into '$BRANCH'..."
  MERGE_ARGS=(--no-edit -m "Merge '$UPSTREAM_REF' into '$BRANCH'")
  if [[ -z "$MERGE_BASE" ]]; then
    MERGE_ARGS+=(--allow-unrelated-histories)
  fi
  if git merge "${MERGE_ARGS[@]}" "$UPSTREAM_REF"; then
    ok "Merge completed."
  else
    print_conflict_help "merge" "$BACKUP_TAG"
    exit 1
  fi
  MODE="merge"
fi

push_result "$MODE"
restore_stash "$STASHED"
rm -f "$STATE_FILE"

echo
ok "'$BRANCH' is now in sync with '$UPSTREAM_REF'."
info "Backup tag kept locally: $BACKUP_TAG"
info "Delete it when you are happy with the result: git tag -d '$BACKUP_TAG'"
