#!/bin/bash
#
# Claude Code Session Manager
#
# A tool to list and manage sessions across all workspaces.
# This enables cross-workspace session discovery and copying.
#
# Usage:
#   ./session-manager.sh list              # List all sessions across workspaces
#   ./session-manager.sh list --current    # List sessions for current directory only
#   ./session-manager.sh info <session-id> # Show details for a specific session
#   ./session-manager.sh copy <session-id> # Copy session to current directory
#

set -e

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
PROJECTS_DIR="$CLAUDE_DIR/projects"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Convert path to Claude's directory name format
path_to_dirname() {
    echo "$1" | sed 's|/|-|g'
}

# Convert Claude's directory name back to path
dirname_to_path() {
    echo "$1" | sed 's|^-|/|' | sed 's|-|/|g'
}

# Get current directory's session folder
get_current_project_dir() {
    local cwd=$(pwd)
    local dirname=$(path_to_dirname "$cwd")
    echo "$PROJECTS_DIR/$dirname"
}

# Extract session info from first line of JSONL file
get_session_info() {
    local file="$1"
    head -1 "$file" 2>/dev/null | jq -r '[.sessionId, .cwd, .gitBranch, .timestamp] | @tsv' 2>/dev/null
}

# Get session name (if renamed) from session file
get_session_name() {
    local file="$1"
    # Look for rename events or session metadata
    grep -o '"sessionName":"[^"]*"' "$file" 2>/dev/null | tail -1 | sed 's/"sessionName":"//;s/"//' || echo ""
}

# Count messages in session
count_messages() {
    local file="$1"
    wc -l < "$file" 2>/dev/null || echo "0"
}

# Get last activity timestamp
get_last_activity() {
    local file="$1"
    tail -1 "$file" 2>/dev/null | jq -r '.timestamp' 2>/dev/null || echo "unknown"
}

# List all sessions
cmd_list() {
    local current_only=false

    if [[ "$1" == "--current" ]]; then
        current_only=true
    fi

    if [[ ! -d "$PROJECTS_DIR" ]]; then
        echo -e "${RED}No sessions found. Projects directory does not exist: $PROJECTS_DIR${NC}"
        exit 1
    fi

    echo -e "${BOLD}Claude Code Sessions${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    local current_cwd=$(pwd)
    local found_sessions=0

    for project_dir in "$PROJECTS_DIR"/*; do
        if [[ ! -d "$project_dir" ]]; then
            continue
        fi

        local workspace=$(dirname_to_path "$(basename "$project_dir")")

        # Skip if --current and not current directory
        if $current_only && [[ "$workspace" != "$current_cwd" ]]; then
            continue
        fi

        # Find session files (exclude agent-* files which are subagents)
        local session_files=$(find "$project_dir" -maxdepth 1 -name "*.jsonl" ! -name "agent-*" 2>/dev/null)

        if [[ -z "$session_files" ]]; then
            continue
        fi

        # Workspace header
        if [[ "$workspace" == "$current_cwd" ]]; then
            echo -e "${GREEN}📁 $workspace ${BOLD}(current)${NC}"
        else
            echo -e "${BLUE}📁 $workspace${NC}"
        fi

        while IFS= read -r session_file; do
            if [[ ! -f "$session_file" ]]; then
                continue
            fi

            local filename=$(basename "$session_file" .jsonl)
            local info=$(get_session_info "$session_file")
            local session_id=$(echo "$info" | cut -f1)
            local git_branch=$(echo "$info" | cut -f3)
            local created=$(echo "$info" | cut -f4)
            local msg_count=$(count_messages "$session_file")
            local last_activity=$(get_last_activity "$session_file")
            local session_name=$(get_session_name "$session_file")

            # Format timestamps
            local created_fmt=$(date -d "$created" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$created")
            local last_fmt=$(date -d "$last_activity" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "$last_activity")

            # Display session
            echo -e "   ${YELLOW}●${NC} ${BOLD}$session_id${NC}"
            if [[ -n "$session_name" ]]; then
                echo -e "     Name: ${CYAN}$session_name${NC}"
            fi
            if [[ -n "$git_branch" && "$git_branch" != "null" ]]; then
                echo -e "     Branch: $git_branch"
            fi
            echo -e "     Messages: $msg_count | Last: $last_fmt"
            echo ""

            ((found_sessions++))
        done <<< "$session_files"
    done

    if [[ $found_sessions -eq 0 ]]; then
        echo -e "${YELLOW}No sessions found.${NC}"
    else
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "Total: ${BOLD}$found_sessions${NC} session(s)"
        echo ""
        echo -e "${YELLOW}Tip:${NC} Use 'claude --resume <session-id>' to resume a session"
    fi
}

# Show info for specific session
cmd_info() {
    local target_id="$1"

    if [[ -z "$target_id" ]]; then
        echo -e "${RED}Error: Session ID required${NC}"
        echo "Usage: $0 info <session-id>"
        exit 1
    fi

    # Search for session across all workspaces
    for project_dir in "$PROJECTS_DIR"/*; do
        if [[ ! -d "$project_dir" ]]; then
            continue
        fi

        for session_file in "$project_dir"/*.jsonl; do
            if [[ ! -f "$session_file" ]]; then
                continue
            fi

            local filename=$(basename "$session_file" .jsonl)

            # Check if this is the session (by filename or by sessionId in content)
            if [[ "$filename" == "$target_id" ]] || head -1 "$session_file" | grep -q "\"sessionId\":\"$target_id\""; then
                local workspace=$(dirname_to_path "$(basename "$project_dir")")
                local info=$(get_session_info "$session_file")
                local session_id=$(echo "$info" | cut -f1)
                local git_branch=$(echo "$info" | cut -f3)
                local created=$(echo "$info" | cut -f4)
                local msg_count=$(count_messages "$session_file")
                local last_activity=$(get_last_activity "$session_file")
                local file_size=$(du -h "$session_file" | cut -f1)

                echo -e "${BOLD}Session Details${NC}"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo -e "Session ID:  ${YELLOW}$session_id${NC}"
                echo -e "Workspace:   $workspace"
                echo -e "Git Branch:  ${git_branch:-N/A}"
                echo -e "Created:     $created"
                echo -e "Last Active: $last_activity"
                echo -e "Messages:    $msg_count"
                echo -e "File Size:   $file_size"
                echo -e "File Path:   $session_file"
                echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
                echo ""
                echo -e "${YELLOW}To resume this session:${NC}"
                echo -e "  cd $workspace && claude --resume $session_id"
                echo ""
                echo -e "${YELLOW}To copy to current directory:${NC}"
                echo -e "  $0 copy $session_id"
                return 0
            fi
        done
    done

    echo -e "${RED}Session not found: $target_id${NC}"
    exit 1
}

# Copy session to current directory
cmd_copy() {
    local target_id="$1"

    if [[ -z "$target_id" ]]; then
        echo -e "${RED}Error: Session ID required${NC}"
        echo "Usage: $0 copy <session-id>"
        exit 1
    fi

    local current_cwd=$(pwd)
    local current_project_dir=$(get_current_project_dir)

    # Search for source session
    local source_file=""
    local source_workspace=""

    for project_dir in "$PROJECTS_DIR"/*; do
        if [[ ! -d "$project_dir" ]]; then
            continue
        fi

        for session_file in "$project_dir"/*.jsonl; do
            if [[ ! -f "$session_file" ]]; then
                continue
            fi

            local filename=$(basename "$session_file" .jsonl)

            if [[ "$filename" == "$target_id" ]] || head -1 "$session_file" | grep -q "\"sessionId\":\"$target_id\""; then
                source_file="$session_file"
                source_workspace=$(dirname_to_path "$(basename "$project_dir")")
                break 2
            fi
        done
    done

    if [[ -z "$source_file" ]]; then
        echo -e "${RED}Session not found: $target_id${NC}"
        exit 1
    fi

    if [[ "$source_workspace" == "$current_cwd" ]]; then
        echo -e "${YELLOW}Session already belongs to current directory.${NC}"
        exit 0
    fi

    # Create target directory if needed
    mkdir -p "$current_project_dir"

    # Generate new session ID for the copy
    local new_session_id=$(uuidgen | tr '[:upper:]' '[:lower:]')
    local target_file="$current_project_dir/$new_session_id.jsonl"

    echo -e "${BOLD}Copying Session${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "Source:      $target_id"
    echo -e "From:        $source_workspace"
    echo -e "To:          $current_cwd"
    echo -e "New ID:      $new_session_id"
    echo ""

    # Copy and transform the session file
    # Update cwd in all entries to point to current directory
    jq -c --arg new_cwd "$current_cwd" --arg new_id "$new_session_id" \
        '.cwd = $new_cwd | if .sessionId then .sessionId = $new_id else . end' \
        "$source_file" > "$target_file"

    if [[ $? -eq 0 ]]; then
        echo -e "${GREEN}✓ Session copied successfully!${NC}"
        echo ""
        echo -e "${YELLOW}To resume the copied session:${NC}"
        echo -e "  claude --resume $new_session_id"
    else
        echo -e "${RED}Failed to copy session${NC}"
        rm -f "$target_file"
        exit 1
    fi
}

# Show help
cmd_help() {
    echo -e "${BOLD}Claude Code Session Manager${NC}"
    echo ""
    echo "A tool to manage Claude Code sessions across workspaces."
    echo ""
    echo -e "${YELLOW}Usage:${NC}"
    echo "  $0 <command> [options]"
    echo ""
    echo -e "${YELLOW}Commands:${NC}"
    echo "  list              List all sessions across all workspaces"
    echo "  list --current    List sessions for current directory only"
    echo "  info <id>         Show detailed info for a session"
    echo "  copy <id>         Copy a session to current directory"
    echo "  help              Show this help message"
    echo ""
    echo -e "${YELLOW}Examples:${NC}"
    echo "  $0 list                                    # See all sessions"
    echo "  $0 info d2971abf-8245-4887-9023-5f1e9bd03efd  # Get session details"
    echo "  $0 copy d2971abf-8245-4887-9023-5f1e9bd03efd  # Copy to current dir"
    echo ""
    echo -e "${YELLOW}Session Storage:${NC}"
    echo "  Sessions are stored in: $PROJECTS_DIR/"
    echo "  Each workspace has its own subdirectory."
}

# Main
case "${1:-help}" in
    list)
        cmd_list "$2"
        ;;
    info)
        cmd_info "$2"
        ;;
    copy)
        cmd_copy "$2"
        ;;
    help|--help|-h)
        cmd_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        echo "Run '$0 help' for usage."
        exit 1
        ;;
esac
