# Osaurus Tools Repository

Central registry for community tools and plugins for [Osaurus](https://github.com/dinoki-ai/osaurus).

## Official System Tools

| Plugin ID            | Description                            | Tools                                                                                                                                                            |
| -------------------- | -------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `osaurus.time`       | Time and date utilities                | `current_time`, `format_date`                                                                                                                                    |
| `osaurus.git`        | Git repository utilities               | `git_status`, `git_log`, `git_diff`, `git_branch`                                                                                                                |
| `osaurus.browser`    | Agent-friendly headless WebKit browser | `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_select`, `browser_hover`, `browser_scroll`, `browser_press_key`, `browser_wait_for`, `browser_screenshot`, `browser_execute_script` |
| `osaurus.fetch`      | HTTP client for web requests           | `fetch`, `fetch_json`, `fetch_html`, `download`                                                                                                                  |
| `osaurus.search`     | Web search via DuckDuckGo              | `search`, `search_news`, `search_images`                                                                                                                         |
| `osaurus.filesystem` | File system operations                 | `read_file`, `write_file`, `list_directory`, `create_directory`, `delete_file`, `move_file`, `search_files`, `get_file_info`                                    |

### Installation

```bash
osaurus tools install osaurus.time
osaurus tools install osaurus.git
osaurus tools install osaurus.browser
osaurus tools install osaurus.fetch
osaurus tools install osaurus.search
osaurus tools install osaurus.filesystem
```

## Adding a Plugin to the Registry

1. Fork this repository
2. Create `plugins/<your.plugin.id>.json` (e.g., `mycompany.mytool.json`)
3. Fill in the plugin specification (see schema below)
4. Submit a Pull Request — CI will validate your JSON automatically

## Plugin Specification

Plugins are distributed as a `.dylib` in a zip file. The manifest is embedded in the plugin binary.

```json
{
  "plugin_id": "mycompany.mytool",
  "name": "My Cool Tool",
  "homepage": "https://example.com/mytool",
  "license": "MIT",
  "authors": ["Jane Doe"],
  "capabilities": {
    "tools": [
      {
        "name": "mytool",
        "description": "Does something cool"
      }
    ]
  },
  "public_keys": {
    "minisign": "RWxxxxxxxxxxxxxxxx"
  },
  "versions": [
    {
      "version": "1.0.0",
      "release_date": "2025-01-01",
      "notes": "Initial release",
      "requires": {
        "osaurus_min_version": "0.5.0"
      },
      "artifacts": [
        {
          "os": "macos",
          "arch": "arm64",
          "url": "https://example.com/downloads/mytool-1.0.0.zip",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "minisign": {
            "signature": "RWxxxxxxxxxxxxxxxx",
            "key_id": "xxxxxxxx"
          }
        }
      ]
    }
  ]
}
```

### Required Fields

| Field         | Description                                                          |
| ------------- | -------------------------------------------------------------------- |
| `plugin_id`   | Unique identifier in dot-separated format (e.g., `mycompany.mytool`) |
| `name`        | Display name                                                         |
| `public_keys` | Dictionary of public keys for signature verification                 |
| `versions`    | List of available versions                                           |

### Optional Fields

| Field          | Description                         |
| -------------- | ----------------------------------- |
| `homepage`     | Plugin homepage or repository URL   |
| `license`      | License (e.g., "MIT", "Apache-2.0") |
| `authors`      | List of author names                |
| `capabilities` | Tools and capabilities description  |

### Version Entry

| Field                          | Required | Description                      |
| ------------------------------ | -------- | -------------------------------- |
| `version`                      | Yes      | Semantic version (e.g., "1.0.0") |
| `artifacts`                    | Yes      | List of downloadable binaries    |
| `release_date`                 | No       | Date string (ISO 8601)           |
| `notes`                        | No       | Release notes                    |
| `requires.osaurus_min_version` | No       | Minimum Osaurus version          |

### Artifact Entry

| Field       | Required | Description                                   |
| ----------- | -------- | --------------------------------------------- |
| `os`        | Yes      | Operating system (`macos`)                    |
| `arch`      | Yes      | CPU architecture (`arm64`)                    |
| `url`       | Yes      | Direct download URL for the zip               |
| `sha256`    | Yes      | SHA-256 checksum                              |
| `minisign`  | Yes      | Minisign signature (`signature` and `key_id`) |
| `min_macos` | No       | Minimum macOS version (e.g., "13.0")          |
| `size`      | No       | File size in bytes                            |

## Code Signing

macOS plugins (`.dylib`) **must be code-signed** with a valid Developer ID Application certificate. Unsigned plugins will be blocked by Gatekeeper when downloaded.

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  libMyPlugin.dylib
```

## Artifact Signing (Minisign)

Sign your release zip to ensure integrity:

```bash
# Install Minisign
brew install minisign

# Generate key pair (once)
minisign -G -p minisign.pub -s minisign.key

# Sign your zip
minisign -S -s minisign.key -m myplugin-macos-arm64.zip
```

Add to your plugin spec:

- Public key contents → `public_keys.minisign`
- Signature contents → `versions[].artifacts[].minisign.signature`

## Development

### Building System Tools

```bash
# Build a single tool
./scripts/build-tool.sh time

# Build all tools
./scripts/build-tool.sh all

# Build with specific version
./scripts/build-tool.sh git --version 1.0.0
```

Build output goes to `build/<tool-name>/`.

### Creating a New Tool

1. Create directory structure:

   ```
   tools/mytool/
   ├── Package.swift
   └── Sources/OsaurusMytool/Plugin.swift
   ```

2. Implement the plugin using the [C ABI](https://github.com/dinoki-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md). The manifest is embedded directly in `Plugin.swift` via the `get_manifest` function. See existing tools for examples.

3. Build and test:

   ```bash
   ./scripts/build-tool.sh mytool
   osaurus tools install ./build/mytool/osaurus.mytool-1.0.0.zip
   ```

### Releasing

```bash
# Release a single tool
./scripts/release.sh time
git push origin time-1.0.0

# Release all tools
./scripts/release.sh all
git push origin --tags

# Release with explicit version
./scripts/release.sh time 1.0.0
```

The GitHub Actions workflow will:

1. Build the plugin for macOS arm64
2. Create a GitHub Release with the artifact
3. Open a PR to update the registry JSON

## License

MIT License — see [LICENSE](LICENSE) for details.
