#!/usr/bin/env bash
set -euo pipefail

: "${DISCORD_WEBHOOK:?DISCORD_WEBHOOK is required}"
: "${PLUGIN_ID:?PLUGIN_ID is required}"
: "${VERSION:?VERSION is required}"

# Ensure jq is available
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not found; attempting to install..."
  apt-get update && apt-get install -y jq || {
    echo "jq is required and could not be installed." >&2
    exit 1
  }
fi

jq -n \
  --arg content  "🔧 **New Tool Update!**" \
  --arg plugin   "$PLUGIN_ID" \
  --arg version  "$VERSION" \
  --arg page     "[View Release](https://github.com/dinoki-ai/osaurus-tools/releases/tag/${PLUGIN_ID}-${VERSION})" \
  '{
    content: $content,
    embeds: [
      {
        title: ($plugin + " v" + $version),
        color: 5814783,
        fields: [
          { name: "📋 Release", value: $page, inline: true }
        ],
        footer: { text: "Released via GitHub Actions" },
        timestamp: (now | strftime("%Y-%m-%dT%H:%M:%S.000Z"))
      }
    ]
  }' > payload.json

curl -f -X POST -H "Content-Type: application/json" --data @payload.json "$DISCORD_WEBHOOK"
echo "Discord notification sent"
