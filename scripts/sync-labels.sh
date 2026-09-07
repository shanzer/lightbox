#!/usr/bin/env bash
#
# Apply .github/labels.json to a GitHub repo's label set.
#
# Labels are part of the conventions in docs/agents/issue-conventions.md — the priority
# ladder and the triage states are referenced by name there and by both agent skills. A
# repo missing them silently degrades every skill that applies one. Keeping the set in a
# file makes it reproducible and reviewable instead of a sequence of one-off gh calls
# nobody can audit later.
#
# Usage:
#   scripts/sync-labels.sh [--repo OWNER/NAME] [--dry-run] [--prune]
#
#   --repo     Target repo. Defaults to whatever `gh` infers from the current clone.
#   --dry-run  Print what would change; touch nothing.
#   --prune    Also DELETE labels present on the repo but absent from labels.json.
#              Off by default: deleting a label strips it from every issue that carries
#              it, and that is not recoverable from this script.
set -euo pipefail

LABELS_FILE=".github/labels.json"
REPO=""
DRY_RUN=false
PRUNE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="${2:?--repo needs a value}"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --prune)   PRUNE=true; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for cmd in gh jq; do
  command -v "$cmd" >/dev/null || { echo "error: $cmd is required but not installed" >&2; exit 1; }
done
gh auth status >/dev/null 2>&1 || { echo "error: gh is not authenticated — run 'gh auth login'" >&2; exit 1; }
[[ -f "$LABELS_FILE" ]] || { echo "error: $LABELS_FILE not found (run from the repo root)" >&2; exit 1; }

# Fail before touching the repo rather than halfway through a partial apply.
jq -e 'type == "array" and length > 0' "$LABELS_FILE" >/dev/null \
  || { echo "error: $LABELS_FILE must be a non-empty JSON array" >&2; exit 1; }
jq -e 'all(.[]; (.name|type=="string" and length>0)
              and (.description|type=="string")
              and (.color|test("^[0-9a-fA-F]{6}$")))' "$LABELS_FILE" >/dev/null \
  || { echo "error: every label needs a name, a description, and a 6-digit hex color (no '#')" >&2; exit 1; }

REPO_ARGS=()
[[ -n "$REPO" ]] && REPO_ARGS=(--repo "$REPO")
TARGET="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"

echo "Syncing labels from $LABELS_FILE -> $TARGET"
$DRY_RUN && echo "(dry run — nothing will be changed)"

# --force upserts: creates when absent, updates color/description when present. That makes
# the script idempotent, so it is safe to re-run after editing labels.json.
count=0
while IFS=$'\t' read -r name description color; do
  if $DRY_RUN; then
    echo "  would upsert  $name"
  else
    gh label create "$name" --description "$description" --color "$color" --force ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} >/dev/null
    echo "  upserted  $name"
  fi
  count=$((count + 1))
done < <(jq -r '.[] | [.name, .description, .color] | @tsv' "$LABELS_FILE")

echo "$count labels processed."

# Report drift whether or not we are pruning: knowing an unmanaged label exists is useful
# even when deleting it is the wrong call.
# `mapfile` and expanding an empty array under `set -u` both need bash >= 4.4; macOS
# ships 3.2. The read loop and the `${arr[@]+...}` guard work on both.
extra=()
while IFS= read -r line; do
  [[ -n "$line" ]] && extra+=("$line")
done < <(
  comm -13 \
    <(jq -r '.[].name' "$LABELS_FILE" | sort) \
    <(gh label list --limit 200 --json name --jq '.[].name' ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} | sort)
)

if ((${#extra[@]})); then
  echo
  echo "Present on $TARGET but not in $LABELS_FILE:"
  printf '  %s\n' "${extra[@]}"
  if $PRUNE; then
    for name in "${extra[@]}"; do
      if $DRY_RUN; then
        echo "  would DELETE  $name"
      else
        gh label delete "$name" --yes ${REPO_ARGS[@]+"${REPO_ARGS[@]}"} && echo "  deleted  $name"
      fi
    done
  else
    echo "Left alone. Re-run with --prune to delete them (this strips them from every issue)."
  fi
fi
