# Osaurus Tools Repository

This repository serves as the central registry for community tools and plugins for [Osaurus](https://github.com/dinoki-ai/osaurus).

## Official System Tools

These tools are maintained by the Osaurus team and built directly from this repository:

| Plugin ID            | Description                        | Tools                                                                                                                                                          |
| -------------------- | ---------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `osaurus.time`       | Time and date utilities            | `current_time`, `format_date`                                                                                                                                  |
| `osaurus.git`        | Git repository utilities           | `git_status`, `git_log`, `git_diff`, `git_branch`                                                                                                              |
| `osaurus.browser`    | Headless WebKit browser automation | `browser_navigate`, `browser_get_content`, `browser_get_html`, `browser_execute_script`, `browser_click`, `browser_type`, `browser_screenshot`, `browser_wait` |
| `osaurus.fetch`      | HTTP client for web requests       | `fetch`, `fetch_json`, `fetch_html`, `download`                                                                                                                |
| `osaurus.search`     | Web search via DuckDuckGo          | `search`, `search_news`, `search_images`                                                                                                                       |
| `osaurus.filesystem` | File system operations             | `read_file`, `write_file`, `list_directory`, `create_directory`, `delete_file`, `move_file`, `search_files`, `get_file_info`                                   |

### Installation

```bash
# Install via Osaurus CLI
osaurus tools install osaurus.time
osaurus tools install osaurus.git
osaurus tools install osaurus.browser
osaurus tools install osaurus.fetch
osaurus tools install osaurus.search
osaurus tools install osaurus.filesystem
```

## How to Add a Tool

1.  **Fork this repository.**
2.  Create a new JSON file in the `plugins/` directory. The filename should match your plugin ID (e.g., `mycompany.mytool.json`).
3.  Fill in the plugin specification according to the schema below.
4.  **Submit a Pull Request.** Our CI will automatically validate your JSON file.

## Plugin Specification Schema

Your JSON file must adhere to the following structure:

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
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        }
      ]
    }
  ]
}
```

### Fields

- **`plugin_id`** (Required): A unique identifier for your plugin in dot-separated format (e.g., `mycompany.mytool`).
- **`name`** (Optional): Display name of the plugin.
- **`homepage`** (Optional): URL to the plugin's homepage or repository.
- **`license`** (Optional): License of the plugin (e.g., "MIT", "Apache-2.0").
- **`authors`** (Optional): List of author names.
- **`capabilities`** (Optional): Structural capabilities description (e.g., tools).
- **`public_keys`** (Optional): Dictionary of public keys for signature verification (if using Minisign).
- **`versions`** (Required): List of available versions.

### Version Entry

- **`version`** (Required): Semantic version string (e.g., "1.0.0").
- **`release_date`** (Optional): Date string (ISO 8601 preferred).
- **`notes`** (Optional): Release notes.
- **`requires`** (Optional): System requirements.
  - `osaurus_min_version`: Minimum Osaurus version required.
- **`artifacts`** (Required): List of downloadable binaries.

### Artifact

- **`os`** (Required): Operating system (currently supports `macos`).
- **`arch`** (Required): CPU architecture (currently supports `arm64`).
- **`min_macos`** (Optional): Minimum macOS version required (e.g., "13.0").
- **`url`** (Required): Direct download URL for the plugin binary/archive.
- **`sha256`** (Required): SHA-256 checksum of the file at `url`.
- **`size`** (Optional): File size in bytes.
- **`minisign`** (Optional): Minisign signature information.
  - `signature`: The signature string.
  - `key_id`: The key ID used to sign.

---

## Development

### Building System Tools

The `tools/` directory contains source code for official Osaurus system tools.

```bash
# Build a single tool
./scripts/build-tool.sh time

# Build all tools
./scripts/build-tool.sh all

# Build with specific version
./scripts/build-tool.sh git --version 1.0.0
```

Build artifacts are output to `build/<tool-name>/`.

### Creating a New System Tool

1. Create a new directory under `tools/`:

   ```
   tools/mytool/
   ├── Package.swift
   ├── manifest.json
   └── Sources/Plugin/Plugin.swift
   ```

2. Implement the plugin following the C ABI specification (see existing tools for examples).

3. Build and test locally:
   ```bash
   ./scripts/build-tool.sh mytool
   osaurus tools install ./build/mytool/osaurus.mytool-1.0.0.zip
   ```

### Releasing

Use the release script to create tags, then push to trigger GitHub Actions:

```bash
# Release a single tool (uses version from manifest.json)
./scripts/release.sh time
git push origin time-1.0.0

# Release all tools at once
./scripts/release.sh all
git push origin --tags

# Release with explicit version
./scripts/release.sh time 1.0.0
./scripts/release.sh all 1.0.0
```

The workflow will:

1. Build the plugin for macOS arm64
2. Create a GitHub Release with the artifact
3. Open a PR to update the registry JSON with the new version

---

## License

MIT License - see [LICENSE](LICENSE) for details.
