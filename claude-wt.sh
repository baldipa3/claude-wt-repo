#!/usr/bin/env bash

# ==============================================================================
# claude-wt: Automated Git Worktree manager for Claude Code CLI
# ==============================================================================

set -e

show_usage() {
    cat << EOF
Usage: claude-wt <branch-name> [base-branch]
       claude-wt --clean <branch-name>

Options:
  -c, --clean    Remove the worktree and delete the local branch.
  -h, --help     Show this help message.

Examples:
  claude-wt feature/login
  claude-wt feature/login main
  claude-wt --clean feature/login
EOF
}

# Ensure we're inside a Git repository
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "❌ Error: Must be run inside a Git repository."
    exit 1
}

# --- Handle Clean Up Flag ---
if [[ "$1" == "-c" || "$1" == "--clean" ]]; then
    BRANCH_NAME="$2"
    if [[ -z "$BRANCH_NAME" ]]; then
        echo "❌ Error: Branch name required for cleanup."
        show_usage
        exit 1
    fi

    WORKTREE_DIR="$REPO_ROOT/.worktrees/$BRANCH_NAME"

    echo "🧹 Cleaning up worktree for '$BRANCH_NAME'..."
    if [ -d "$WORKTREE_DIR" ]; then
        git worktree remove "$WORKTREE_DIR" --force 2>/dev/null || rm -rf "$WORKTREE_DIR"
    fi

    git branch -d "$BRANCH_NAME" 2>/dev/null || echo "ℹ️ Branch '$BRANCH_NAME' not found or not merged."
    echo "✨ Cleaned up $BRANCH_NAME!"
    exit 0
fi

# --- Handle Help Flag ---
if [[ "$1" == "-h" || "$1" == "--help" || -z "$1" ]]; then
    show_usage
    exit 0
fi

BRANCH_NAME="$1"
BASE_BRANCH="${2:-main}"
WORKTREE_DIR="$REPO_ROOT/.worktrees/$BRANCH_NAME"

# --- 1. Create / Checkout Worktree ---
if [ -d "$WORKTREE_DIR" ]; then
    echo "📂 Worktree directory already exists at $WORKTREE_DIR. Entering session..."
else
    mkdir -p "$REPO_ROOT/.worktrees"
    
    # Check if local or remote branch already exists
    if git show-ref --verify --quiet "refs/heads/$BRANCH_NAME" || git show-ref --verify --quiet "refs/remotes/origin/$BRANCH_NAME"; then
        echo "🌿 Branch '$BRANCH_NAME' already exists. Attaching worktree..."
        git worktree add "$WORKTREE_DIR" "$BRANCH_NAME"
    else
        echo "🚀 Creating new branch '$BRANCH_NAME' off '$BASE_BRANCH'..."
        git worktree add -b "$BRANCH_NAME" "$WORKTREE_DIR" "$BASE_BRANCH"
    fi
fi

# --- 2. Setup Shared Assets / Symlinks ---
echo "🔗 Setting up shared workspace assets..."

# Symlink .env if present in root
if [ -f "$REPO_ROOT/.env" ] && [ ! -f "$WORKTREE_DIR/.env" ]; then
    ln -s "$REPO_ROOT/.env" "$WORKTREE_DIR/.env"
    echo "  └─ Linked .env"
fi

# Symlink Rails master key if present
if [ -f "$REPO_ROOT/config/master.key" ] && [ ! -f "$WORKTREE_DIR/config/master.key" ]; then
    mkdir -p "$WORKTREE_DIR/config"
    ln -s "$REPO_ROOT/config/master.key" "$WORKTREE_DIR/config/master.key"
    echo "  └─ Linked config/master.key"
fi

# Symlink node_modules if present in root
if [ -d "$REPO_ROOT/node_modules" ] && [ ! -d "$WORKTREE_DIR/node_modules" ]; then
    ln -s "$REPO_ROOT/node_modules" "$WORKTREE_DIR/node_modules"
    echo "  └─ Linked node_modules"
fi

# Symlink vendor/bundle if present in root
if [ -d "$REPO_ROOT/vendor/bundle" ] && [ ! -d "$WORKTREE_DIR/vendor/bundle" ]; then
    mkdir -p "$WORKTREE_DIR/vendor"
    ln -s "$REPO_ROOT/vendor/bundle" "$WORKTREE_DIR/vendor/bundle"
    echo "  └─ Linked vendor/bundle"
fi

# --- 3. Launch Claude Code ---
echo "⚡ Launching Claude Code in isolated worktree..."
echo "------------------------------------------------"
cd "$WORKTREE_DIR"
claude

# --- 4. Post-Session Cleanup Prompt ---
echo "------------------------------------------------"
read -p "❓ Do you want to remove this worktree now? (y/N): " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    cd "$REPO_ROOT"
    git worktree remove "$WORKTREE_DIR" --force
    echo "✨ Worktree removed. (Branch '$BRANCH_NAME' preserved)"
else
    echo "📌 Worktree preserved at: $WORKTREE_DIR"
fi
