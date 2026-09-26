#!/usr/bin/env bash

# ==============================================================================
# claude-wt: Automated Git Worktree manager for Claude Code CLI
# ==============================================================================

set -e

show_usage() {
    cat << EOF
Usage: claude-wt <branch-name> [base-branch]
       claude-wt -d <branch-name>
       claude-wt --clean <branch-name>

Options:
  -d, --docker-target  Serve a worktree (or the main checkout) from Docker,
                       uncommitted changes included. Use 'main' to go back.
  -c, --clean          Remove the worktree and delete the local branch.
  -u, --update         Update claude-wt from GitHub.
  -h, --help           Show this help message.

Examples:
  claude-wt feature/login
  claude-wt feature/login main
  claude-wt -d feature/login
  claude-wt --clean feature/login
EOF
}

# --- Handle Update Flag ---
if [[ "$1" == "-u" || "$1" == "--update" ]]; then
    echo "🔄 Updating claude-wt from GitHub..."
    curl -fsSL https://raw.githubusercontent.com/baldipa3/claude-wt-repo/refs/heads/main/claude-wt.sh -o ~/.local/bin/claude-wt
    chmod +x ~/.local/bin/claude-wt
    echo "✨ claude-wt has been updated to the latest version!"
    exit 0
fi

# Ensure we're inside a Git repository
git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "❌ Error: Must be run inside a Git repository."
    exit 1
}

# The MAIN working tree — the folder Docker mounts — even when this script is run
# from inside a linked worktree. `git rev-parse --show-toplevel` would return the
# worktree itself, so every path below (.worktrees/, the Docker checkout, the symlink
# sources) would silently point at the wrong place. `git worktree list` reports the
# main working tree first, always.
REPO_ROOT=$(git worktree list --porcelain | awk 'NR==1 && $1 == "worktree" { print substr($0, 10); exit }')
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"

# --- Docker wiring (override per project via the environment) ---
has_compose_file() {
    local dir="$1" name
    for name in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        [ -f "$dir/$name" ] && return 0
    done
    return 1
}

# The compose file lives in platform/development, and Compose reads that folder's .env,
# so LABNET_PATH must be written there. platform/ is kept as a fallback for older layouts.
default_compose_dir() {
    local dir
    for dir in "$REPO_ROOT/../platform/development" "$REPO_ROOT/../platform"; do
        if has_compose_file "$dir"; then
            (cd "$dir" && pwd)
            return
        fi
    done
    echo "$REPO_ROOT/../platform/development"
}

COMPOSE_DIR="${CLAUDE_WT_COMPOSE_DIR:-$(default_compose_dir)}"
COMPOSE_PROJECT="${CLAUDE_WT_COMPOSE_PROJECT:-gmpilot-net}"
COMPOSE_SERVICE="${CLAUDE_WT_COMPOSE_SERVICE:-rails}"
PATH_VAR="${CLAUDE_WT_PATH_VAR:-LABNET_PATH}"

# Which directory should Docker serve for this name? A worktree if one exists,
# otherwise the main checkout.
resolve_target_dir() {
    local name="$1"

    if [ -d "$REPO_ROOT/.worktrees/$name" ]; then
        echo "$REPO_ROOT/.worktrees/$name"
    elif [ "$name" = "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD)" ] || [ "$name" = "main" ]; then
        echo "$REPO_ROOT"
    else
        return 1
    fi
}

# A directory served at /app must not depend on host-absolute symlinks: they do not
# resolve inside the container. Real files only.
prepare_for_docker() {
    local dir="$1"

    if [ -f "$REPO_ROOT/config/master.key" ]; then
        if [ -L "$dir/config/master.key" ] || [ ! -e "$dir/config/master.key" ]; then
            mkdir -p "$dir/config"
            rm -f "$dir/config/master.key"
            cp "$REPO_ROOT/config/master.key" "$dir/config/master.key"
            echo "  └─ Copied config/master.key (a symlink breaks inside Docker)"
        fi
    fi

    # Compiled CSS is gitignored build output, so a fresh worktree has none and the
    # app renders unstyled — which also breaks Capybara system specs.
    if [ -f "$REPO_ROOT/app/assets/builds/tailwind.css" ] && [ ! -f "$dir/app/assets/builds/tailwind.css" ]; then
        mkdir -p "$dir/app/assets/builds"
        cp "$REPO_ROOT/app/assets/builds/tailwind.css" "$dir/app/assets/builds/tailwind.css"
        echo "  └─ Copied app/assets/builds/tailwind.css"
    fi
}

# Repoint the bind mount at a directory and recreate the container. This serves the
# working tree as it is on disk — uncommitted changes included — which is the whole
# point: test first, commit after.
point_docker_to() {
    local target="$1"
    local env_file="$COMPOSE_DIR/.env"

    if ! has_compose_file "$COMPOSE_DIR"; then
        echo "❌ Error: no compose file found in '$COMPOSE_DIR'."
        echo "   Set CLAUDE_WT_COMPOSE_DIR to the folder that holds docker-compose.yml."
        return 1
    fi

    prepare_for_docker "$target"

    touch "$env_file"
    grep -v "^${PATH_VAR}=" "$env_file" > "$env_file.tmp" 2>/dev/null || true
    mv "$env_file.tmp" "$env_file"
    echo "${PATH_VAR}=${target}" >> "$env_file"

    (cd "$COMPOSE_DIR" && docker compose -p "$COMPOSE_PROJECT" up -d "$COMPOSE_SERVICE")
}

# --- Handle Docker Target Flag ---
if [[ "$1" == "-d" || "$1" == "--docker-target" ]]; then
    TARGET_BRANCH="$2"
    if [[ -z "$TARGET_BRANCH" ]]; then
        echo "❌ Error: Branch name required for docker-target."
        show_usage
        exit 1
    fi
    TARGET_DIR=$(resolve_target_dir "$TARGET_BRANCH") || {
        echo "❌ Error: no worktree at '$REPO_ROOT/.worktrees/$TARGET_BRANCH'."
        echo "   Create one first:  claude-wt $TARGET_BRANCH"
        exit 1
    }

    echo "🐳 Pointing Docker at: $TARGET_DIR"
    point_docker_to "$TARGET_DIR"
    echo "✅ Container '$COMPOSE_SERVICE' now serves $TARGET_DIR — uncommitted changes included."
    exit 0
fi

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

    # Never leave Docker mounted on a directory that is about to disappear.
    if grep -qx "${PATH_VAR}=${WORKTREE_DIR}" "$COMPOSE_DIR/.env" 2>/dev/null; then
        echo "🐳 Docker was serving this worktree — pointing it back at $REPO_ROOT..."
        point_docker_to "$REPO_ROOT" || true
    fi

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

# Rails master key and compiled assets are COPIED, not symlinked — see
# prepare_for_docker: a host-absolute symlink is a broken link inside the container.
prepare_for_docker "$WORKTREE_DIR"

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

# --- 3. Auto-point Docker at this worktree ---
echo "🐳 Pointing Docker at $WORKTREE_DIR..."
point_docker_to "$WORKTREE_DIR" || echo "  └─ ⚠️ Could not repoint Docker. Run 'claude-wt -d $BRANCH_NAME' once it is up."

# --- 4. Launch Claude Code ---
echo "⚡ Launching Claude Code in isolated worktree..."
echo "------------------------------------------------"
cd "$WORKTREE_DIR"
claude

# --- 5. Post-Session Cleanup Prompt ---
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
