#!/bin/bash
#
# Create release tags for Osaurus plugins
#
# Usage:
#   ./scripts/release.sh <tool-name> [version]   Release a single tool
#   ./scripts/release.sh all [version]           Release all tools
#
# Examples:
#   ./scripts/release.sh time                    # Uses version from Plugin.swift
#   ./scripts/release.sh time 1.0.0              # Explicit version
#   ./scripts/release.sh all                     # Release all tools with their Plugin.swift versions
#   ./scripts/release.sh all 1.0.0               # Release all tools with same version
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }
print_header() { echo -e "${BLUE}$1${NC}"; }

if [ $# -lt 2 ]; then
    echo "Usage: $0 <tool-name|all> <version>"
    echo ""
    echo "Commands:"
    echo "  <tool-name>    Release a specific tool (e.g., time, git, browser)"
    echo "  all            Release all tools in the tools/ directory"
    echo ""
    echo "Arguments:"
    echo "  <version>      Version to release (e.g., 1.0.0) - REQUIRED"
    echo ""
    echo "Examples:"
    echo "  $0 time 1.0.0              # Release time v1.0.0"
    echo "  $0 git 2.0.0               # Release git v2.0.0"
    echo "  $0 all 1.0.0               # Release all tools with version 1.0.0"
    exit 1
fi

TOOL_NAME="$1"
VERSION="$2"

# Get plugin_id from Plugin.swift
get_plugin_id() {
    local tool_dir="$1"
    local plugin_swift=$(find "$tool_dir/Sources" -name "Plugin.swift" -type f | head -1)
    grep -o '"plugin_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin_swift" | head -1 | sed 's/.*"plugin_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/'
}

# Create and push tag for a single tool
release_tool() {
    local tool_name="$1"
    local version="$2"
    
    local tool_dir="$ROOT_DIR/tools/$tool_name"
    
    if [ ! -d "$tool_dir" ]; then
        print_error "Tool directory not found: $tool_dir"
        return 1
    fi
    
    local plugin_swift=$(find "$tool_dir/Sources" -name "Plugin.swift" -type f | head -1)
    if [ -z "$plugin_swift" ] || [ ! -f "$plugin_swift" ]; then
        print_error "Plugin.swift not found in $tool_dir/Sources"
        return 1
    fi
    
    local plugin_id=$(get_plugin_id "$tool_dir")
    local tag="${tool_name}-${version}"
    
    echo ""
    print_header "Releasing $plugin_id v$version"
    echo "  Tag: $tag"
    
    # Check if tag already exists
    if git tag -l "$tag" | grep -q "$tag"; then
        print_error "Tag $tag already exists!"
        echo "  To re-release, delete the tag first:"
        echo "    git tag -d $tag"
        echo "    git push origin :refs/tags/$tag"
        return 1
    fi
    
    # Create tag
    print_info "Creating tag $tag..."
    git tag "$tag"
    
    print_success "Tag $tag created"
    return 0
}

# Main logic
TAGS_CREATED=()
FAILED=0

if [ "$TOOL_NAME" == "all" ]; then
    print_header "=========================================="
    print_header "  Releasing all tools v${VERSION}"
    print_header "=========================================="
    
    for tool_path in "$ROOT_DIR/tools"/*/; do
        tool=$(basename "$tool_path")
        if find "$tool_path/Sources" -name "Plugin.swift" -type f | head -1 | grep -q .; then
            if release_tool "$tool" "$VERSION"; then
                TAGS_CREATED+=("${tool}-${VERSION}")
            else
                ((FAILED++))
            fi
        fi
    done
else
    if release_tool "$TOOL_NAME" "$VERSION"; then
        TAGS_CREATED+=("${TOOL_NAME}-${VERSION}")
    else
        FAILED=1
    fi
fi

echo ""
print_header "=========================================="

if [ ${#TAGS_CREATED[@]} -gt 0 ]; then
    print_success "Created ${#TAGS_CREATED[@]} tag(s):"
    for tag in "${TAGS_CREATED[@]}"; do
        echo "  - $tag"
    done
    
    echo ""
    print_info "To push and trigger releases, run:"
    echo ""
    echo "    git push origin ${TAGS_CREATED[*]}"
    echo ""
    echo "Or push all tags:"
    echo ""
    echo "    git push origin --tags"
    echo ""
fi

if [ $FAILED -gt 0 ]; then
    print_error "$FAILED tool(s) failed"
    exit 1
fi

