#!/bin/bash
#
# Build and package Osaurus plugins
#
# Usage:
#   ./scripts/build-tool.sh <tool-name>     Build a single tool
#   ./scripts/build-tool.sh all             Build all tools
#
# Examples:
#   ./scripts/build-tool.sh time
#   ./scripts/build-tool.sh git --version 1.0.0
#   ./scripts/build-tool.sh all
#
# This script:
# 1. Builds the Swift plugin as a dynamic library
# 2. Packages the .dylib and manifest.json into a zip
# 3. Computes SHA256 checksum
# 4. Outputs build artifacts to build/<tool-name>/
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tool-name|all> [--version <version>]"
    echo ""
    echo "Commands:"
    echo "  <tool-name>    Build a specific tool (e.g., time, git)"
    echo "  all            Build all tools in the tools/ directory"
    echo ""
    echo "Options:"
    echo "  --version      Override version from manifest.json"
    echo ""
    echo "Examples:"
    echo "  $0 time"
    echo "  $0 git --version 1.0.0"
    echo "  $0 all"
    exit 1
fi

TOOL_NAME="$1"
VERSION=""

# Parse optional arguments
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Function to build a single tool
build_tool() {
    local tool_name="$1"
    local version_override="$2"

    local tool_dir="$ROOT_DIR/tools/$tool_name"
    local build_output="$ROOT_DIR/build/$tool_name"

    if [ ! -d "$tool_dir" ]; then
        print_error "Tool directory not found: $tool_dir"
        return 1
    fi

    if [ ! -f "$tool_dir/Package.swift" ]; then
        print_error "Package.swift not found in $tool_dir"
        return 1
    fi

    if [ ! -f "$tool_dir/manifest.json" ]; then
        print_error "manifest.json not found in $tool_dir"
        return 1
    fi

    # Extract version from manifest.json if not provided
    local version="$version_override"
    if [ -z "$version" ]; then
        version=$(python3 -c "import json; print(json.load(open('$tool_dir/manifest.json'))['version'])")
    fi

    # Extract plugin_id from manifest.json
    local plugin_id=$(python3 -c "import json; print(json.load(open('$tool_dir/manifest.json'))['plugin_id'])")

    echo ""
    echo "========================================"
    print_info "Building $plugin_id v$version"
    echo "========================================"
    echo "Tool directory: $tool_dir"
    echo "Output directory: $build_output"

    # Clean and create build output directory
    rm -rf "$build_output"
    mkdir -p "$build_output"

    # Build the Swift package
    echo ""
    print_info "Building Swift package..."
    cd "$tool_dir"

    # Get the product name from Package.swift
    local product_name=$(swift package describe --type json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['products'][0]['name'])" 2>/dev/null || echo "")

    if [ -z "$product_name" ]; then
        # Fallback: derive from directory name
        product_name="Osaurus$(echo "$tool_name" | sed 's/.*/\u&/')"
    fi

    echo "Product name: $product_name"

    swift build -c release

    # Find the built dylib
    local dylib_path="$tool_dir/.build/release/lib${product_name}.dylib"

    if [ ! -f "$dylib_path" ]; then
        print_error "Built library not found at $dylib_path"
        echo "Looking for available libraries..."
        find "$tool_dir/.build/release" -name "*.dylib" -type f
        return 1
    fi

    print_success "Built library: $dylib_path"

    # Create staging directory for packaging
    local staging_dir="$build_output/staging"
    mkdir -p "$staging_dir"

    # Copy artifacts to staging
    cp "$dylib_path" "$staging_dir/lib${product_name}.dylib"
    cp "$tool_dir/manifest.json" "$staging_dir/manifest.json"

    # Ad-hoc codesign the dylib (satisfies macOS Gatekeeper requirements)
    print_info "Ad-hoc signing dylib..."
    codesign -s - -f "$staging_dir/lib${product_name}.dylib"
    print_success "Signed: lib${product_name}.dylib"

    # Create the zip archive
    local zip_name="${plugin_id}-${version}.zip"
    local zip_path="$build_output/$zip_name"

    print_info "Creating zip archive..."
    cd "$staging_dir"
    zip -r "$zip_path" .

    # Compute SHA256
    print_info "Computing SHA256..."
    local sha256=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)

    # Get file size
    local size=$(stat -f%z "$zip_path" 2>/dev/null || stat --printf="%s" "$zip_path")

    # Clean up staging
    rm -rf "$staging_dir"

    # Write build info
    cat > "$build_output/build-info.json" <<EOF
{
  "plugin_id": "$plugin_id",
  "version": "$version",
  "artifact": "$zip_name",
  "sha256": "$sha256",
  "size": $size,
  "built_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    echo ""
    print_success "Build complete!"
    echo ""
    echo "  Artifact: $zip_path"
    echo "  SHA256:   $sha256"
    echo "  Size:     $size bytes"
    echo ""

    return 0
}

# Main logic
if [ "$TOOL_NAME" == "all" ]; then
    echo ""
    echo "========================================"
    echo "  Building all tools"
    echo "========================================"

    TOOLS_DIR="$ROOT_DIR/tools"
    FAILED=0
    BUILT=0

    for tool_path in "$TOOLS_DIR"/*/; do
        tool=$(basename "$tool_path")
        if [ -f "$tool_path/Package.swift" ]; then
            if build_tool "$tool" "$VERSION"; then
                ((BUILT++))
            else
                ((FAILED++))
            fi
        fi
    done

    echo ""
    echo "========================================"
    if [ $FAILED -eq 0 ]; then
        print_success "All $BUILT tools built successfully!"
    else
        print_error "$FAILED tool(s) failed to build"
        exit 1
    fi
else
    build_tool "$TOOL_NAME" "$VERSION"
fi
