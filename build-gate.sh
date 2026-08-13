#!/bin/sh
# Wave-4 compile gate helper (worktree-local, not committed).
cd /Users/hsp/Desktop/Luna/.claude/worktrees/agent-aca193ab8e71e0e0e || exit 1
LOG="$1"
shift
nohup xcodebuild "$@" -derivedDataPath build/dd DIAGNOSE_MISSING_TARGET_DEPENDENCIES=NO > "$LOG" 2>&1 &
echo "$!"
