#!/bin/bash
# Script to dynamically generate conf/copilot-config.yaml
# - Fetches latest VS Code stable version
# - Fetches available Copilot models from GitHub API
# - Ensures claude-opus-4.6 uses the claude-opus-4.6-1m model variant

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/conf/copilot-config.yaml"
GITHUB_TOKEN_FILE="$SCRIPT_DIR/litellm-data/github_copilot/access-token"

# --- 1. Get latest VS Code version ---
echo "🔍 Fetching latest VS Code version..."
VSCODE_VERSION=$(curl -s "https://update.code.visualstudio.com/api/releases/stable" | jq -r '.[0]')
if [[ -z "$VSCODE_VERSION" || "$VSCODE_VERSION" == "null" ]]; then
    echo "⚠️  Failed to fetch VS Code version, using fallback 1.109.5"
    VSCODE_VERSION="1.109.5"
fi
echo "✅ VS Code version: $VSCODE_VERSION"

# --- 2. Get GitHub Copilot token ---
if [[ ! -f "$GITHUB_TOKEN_FILE" ]]; then
    echo "❌ GitHub Copilot token not found at $GITHUB_TOKEN_FILE"
    echo "   Run 'make start' first to authenticate with GitHub"
    exit 1
fi
GITHUB_TOKEN=$(cat "$GITHUB_TOKEN_FILE" | tr -d '\n\r ')

# --- 3. Fetch models from Copilot API ---
echo "🔍 Fetching Copilot models..."
MODELS_JSON=$(curl -s -H "Authorization: Bearer $GITHUB_TOKEN" \
    https://api.enterprise.githubcopilot.com/models)

if ! echo "$MODELS_JSON" | jq -e '.data' >/dev/null 2>&1; then
    echo "❌ Failed to fetch models from Copilot API"
    echo "$MODELS_JSON"
    exit 1
fi

# --- 4. Update only the model_list section ---
echo "📝 Updating model_list in $CONFIG_FILE ..."

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Config file not found: $CONFIG_FILE"
    echo "   Please create the config file first with litellm_settings and general_settings."
    exit 1
fi

# Extract everything before "model_list:" (header) and everything after the last model entry (footer)
HEADER_END=$(grep -n '^model_list:' "$CONFIG_FILE" | head -1 | cut -d: -f1)
if [[ -z "$HEADER_END" ]]; then
    echo "❌ Could not find 'model_list:' in $CONFIG_FILE"
    exit 1
fi

# Save header (everything up to and including "model_list:")
head -n "$HEADER_END" "$CONFIG_FILE" > "${CONFIG_FILE}.tmp"

# Find the footer: lines starting with "# To use these models:" onwards
FOOTER_LINE=$(grep -n '^# To use these models:' "$CONFIG_FILE" | head -1 | cut -d: -f1)

# Generate new model entries into temp file
echo "$MODELS_JSON" | jq -r '.data[] | select(.capabilities.type == "chat") | @json' | while IFS= read -r model_json; do
    id=$(echo "$model_json" | jq -r '.id')
    name=$(echo "$model_json" | jq -r '.name')
    vendor=$(echo "$model_json" | jq -r '.vendor')
    state=$(echo "$model_json" | jq -r '.policy.state // "enabled"')
    max_output=$(echo "$model_json" | jq -r '.capabilities.limits.max_output_tokens')
    max_context=$(echo "$model_json" | jq -r '.capabilities.limits.max_context_window_tokens')

    # Determine the litellm model path
    litellm_model="github_copilot/${id}"

    # Special case: claude-opus-4.6 must use the 1m variant
    if [[ "$id" == "claude-opus-4.6" ]]; then
        litellm_model="github_copilot/claude-opus-4.6-1m"
    fi

    cat >> "${CONFIG_FILE}.tmp" <<EOF

  - model_name: ${id}
    litellm_params:
      model: ${litellm_model}
      extra_headers: {"Editor-Version": "vscode/${VSCODE_VERSION}", "Copilot-Integration-Id": "vscode-chat"}
    # ${name} (${vendor}) - ${state}
    # Max tokens: ${max_output}, Context: ${max_context}
EOF
done


# --- 6. Ensure claude-opus-4.7 entry always exists ---
if ! grep -q 'model_name: claude-opus-4-7$' "${CONFIG_FILE}.tmp" 2>/dev/null; then
    cat >> "${CONFIG_FILE}.tmp" <<EOF

  - model_name: claude-opus-4-7
    litellm_params:
      model: github_copilot/claude-opus-4.7-1m-internal
      extra_headers: {"Editor-Version": "vscode/${VSCODE_VERSION}", "Copilot-Integration-Id": "vscode-chat"}
    # Claude Opus 4.7 (Anthropic) - enabled
    # Max tokens: 32000, Context: 200000
EOF
fi

# --- 7. Append original footer ---
if [[ -n "$FOOTER_LINE" ]]; then
    echo "" >> "${CONFIG_FILE}.tmp"
    tail -n +"$FOOTER_LINE" "$CONFIG_FILE" >> "${CONFIG_FILE}.tmp"
else
    # No footer found, add default
    cat >> "${CONFIG_FILE}.tmp" <<'FOOTER'

# To use these models:
# 1. Restart LiteLLM: make stop && make start
# 2. Test with: make test
FOOTER
fi

# Replace original file
mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"

MODEL_COUNT=$(grep -c 'model_name:' "$CONFIG_FILE")
echo "✅ Updated $CONFIG_FILE with $MODEL_COUNT models (vscode/$VSCODE_VERSION)"
