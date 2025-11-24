#!/usr/bin/env python3
import json
import os
import sys
import re
import glob

# Constants for validation
REQUIRED_TOP_LEVEL = {"plugin_id", "versions"}
REQUIRED_VERSION_LEVEL = {"version", "artifacts"}
REQUIRED_ARTIFACT_LEVEL = {"os", "arch", "url", "sha256"}
VALID_OS = {"macos"}
VALID_ARCH = {"arm64"}

# SemVer regex (simplified but robust enough for basic validation)
# Matches 1.0.0, 1.0.0-beta, 1.0.0+build, etc.
SEMVER_REGEX = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$")

def validate_semver(version):
    return bool(SEMVER_REGEX.match(version))

def validate_artifact(artifact, context):
    missing = REQUIRED_ARTIFACT_LEVEL - set(artifact.keys())
    if missing:
        print(f"Error in {context}: Missing required artifact fields: {missing}")
        return False
    
    if artifact["os"] not in VALID_OS:
        print(f"Error in {context}: Invalid OS '{artifact['os']}'. Must be one of {VALID_OS}")
        return False
        
    if artifact["arch"] not in VALID_ARCH:
        print(f"Error in {context}: Invalid Architecture '{artifact['arch']}'. Must be one of {VALID_ARCH}")
        return False

    # URL Check: Verify urls are HTTPS
    if not artifact["url"].startswith("https://"):
        print(f"Error in {context}: URL must start with https://")
        return False
        
    if not re.match(r"^[a-fA-F0-9]{64}$", artifact["sha256"]):
        print(f"Error in {context}: Invalid SHA256 checksum format")
        return False
        
    return True

def validate_version(entry, context):
    missing = REQUIRED_VERSION_LEVEL - set(entry.keys())
    if missing:
        print(f"Error in {context}: Missing required version fields: {missing}")
        return False
        
    if not validate_semver(entry["version"]):
        print(f"Error in {context}: Invalid Semantic Version '{entry['version']}'")
        return False
        
    if not isinstance(entry["artifacts"], list) or not entry["artifacts"]:
        print(f"Error in {context}: 'artifacts' must be a non-empty list")
        return False

    valid = True
    has_macos_arm64 = False
    
    for idx, artifact in enumerate(entry["artifacts"]):
        if not validate_artifact(artifact, f"{context} -> artifact[{idx}]"):
            valid = False
        else:
            if artifact["os"] == "macos" and artifact["arch"] == "arm64":
                has_macos_arm64 = True
            
    # Artifact Check: Ensure at least one macos/arm64 artifact exists per version
    if not has_macos_arm64:
        print(f"Error in {context}: Must contain at least one artifact for macos/arm64")
        valid = False
            
    # Check requirements if present
    if "requires" in entry:
        reqs = entry["requires"]
        if "osaurus_min_version" in reqs:
            if not validate_semver(reqs["osaurus_min_version"]):
                 print(f"Error in {context}: Invalid osaurus_min_version '{reqs['osaurus_min_version']}'")
                 valid = False
                 
    return valid

def validate_plugin_file(filepath, seen_ids):
    print(f"Validating {filepath}...")
    try:
        with open(filepath, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in {filepath}: {e}")
        return False
        
    missing = REQUIRED_TOP_LEVEL - set(data.keys())
    if missing:
        print(f"Error: Missing required top-level fields in {filepath}: {missing}")
        return False
    
    plugin_id = data.get("plugin_id", "")
    
    # Consistency Check: Ensure plugin_id matches the filename
    filename = os.path.basename(filepath)
    if not filename.endswith(".json"):
        print(f"Error: File {filepath} must end in .json")
        return False
        
    expected_id = filename[:-5] # remove .json
    if plugin_id != expected_id:
        print(f"Error: plugin_id '{plugin_id}' does not match filename '{filename}' (expected '{expected_id}')")
        return False
        
    if plugin_id != plugin_id.lower():
        print(f"Error: plugin_id '{plugin_id}' must be lower-case")
        return False

    if not re.match(r"^[a-z0-9]+(\.[a-z0-9]+)+$", plugin_id):
        print(f"Error: plugin_id '{plugin_id}' must be in reverse-DNS format (e.g., com.example.tool)")
        return False

    # Unique Constraint: Ensure no duplicate plugin_ids (case-insensitive)
    lower_id = plugin_id.lower()
    if lower_id in seen_ids:
        print(f"Error: Duplicate plugin_id found: '{plugin_id}'. Another file already uses this ID (case-insensitive match).")
        return False
    seen_ids.add(lower_id)

    if not isinstance(data["versions"], list):
        print(f"Error: 'versions' must be a list in {filepath}")
        return False

    valid = True
    for idx, version_entry in enumerate(data["versions"]):
        if not validate_version(version_entry, f"{filepath} -> version[{idx}]"):
            valid = False
            
    return valid

def main():
    # Look for plugins directory relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    plugins_dir = os.path.join(os.path.dirname(script_dir), "plugins")
    
    if not os.path.isdir(plugins_dir):
        print(f"Error: plugins directory not found at {plugins_dir}")
        sys.exit(1)

    json_files = glob.glob(os.path.join(plugins_dir, "*.json"))
    
    if not json_files:
        print("No plugin files found to validate.")
        # Not an error, just empty repo check
        return 0 

    failed = False
    seen_ids = set()
    
    for json_file in json_files:
        if not validate_plugin_file(json_file, seen_ids):
            failed = True
            
    if failed:
        print("\nValidation FAILED.")
        sys.exit(1)
    else:
        print("\nAll plugins validated successfully.")
        sys.exit(0)

if __name__ == "__main__":
    main()

