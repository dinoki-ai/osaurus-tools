# Osaurus Tools Repository

This repository serves as the central registry for community tools and plugins for [Osaurus](https://github.com/dinoki-ai/osaurus).

## How to Add a Tool

1.  **Fork this repository.**
2.  Create a new JSON file in the `plugins/` directory. The filename should match your plugin ID (e.g., `com.example.mytool.json`).
3.  Fill in the plugin specification according to the schema below.
4.  **Submit a Pull Request.** Our CI will automatically validate your JSON file.

## Plugin Specification Schema

Your JSON file must adhere to the following structure:

```json
{
  "plugin_id": "com.example.mytool",
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
      "release_date": "2023-10-27",
      "notes": "Initial release",
      "requires": {
        "osaurus_min_version": "0.1.0"
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

- **`plugin_id`** (Required): A unique identifier for your plugin, preferably in reverse domain notation.
- **`name`** (Optional): Display name of the plugin.
- **`homepage`** (Optional): URL to the plugin's homepage or repository.
- **`license`** (Optional): License of the plugin (e.g., "MIT", "Apache-2.0").
- **`authors`** (Optional): List of author names.
- **`capabilities`** (Optional): structural capabilities description (e.g. tools).
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
- **`min_macos`** (Optional): Minimum macOS version required (e.g. "13.0").
- **`url`** (Required): Direct download URL for the plugin binary/archive.
- **`sha256`** (Required): SHA-256 checksum of the file at `url`.
- **`size`** (Optional): File size in bytes.
- **`minisign`** (Optional): Minisign signature information.
  - `signature`: The signature string.
  - `key_id`: The key ID used to sign.
