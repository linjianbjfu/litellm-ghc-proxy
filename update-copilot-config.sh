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

# --- 4. Generate YAML ---
echo "📝 Generating $CONFIG_FILE ..."

cat > "$CONFIG_FILE" <<'HEADER'
# GitHub Copilot Models Available
# Usage: Copy the desired models to your copilot-config.yaml

litellm_settings:
  drop_params: true
  max_request_size_mb: 10
  max_response_size_mb: 20
  disable_end_user_cost_tracking: true

general_settings:
  database_url: postgresql://litellm:litellm@postgres:5432/litellm

model_list:
HEADER

# Track whether claude-opus-4.6 was added from API
HAS_CLAUDE_OPUS_46=false

# Parse each chat model and append to YAML
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
        HAS_CLAUDE_OPUS_46=true
    fi

    cat >> "$CONFIG_FILE" <<EOF

  - model_name: ${id}
    litellm_params:
      model: ${litellm_model}
      extra_headers: {"Editor-Version": "vscode/${VSCODE_VERSION}", "Copilot-Integration-Id": "vscode-chat"}
    # ${name} (${vendor}) - ${state}
    # Max tokens: ${max_output}, Context: ${max_context}
EOF
done

# --- 5. Ensure claude-opus-4.6 entry always exists ---
# Check by grepping the generated file (the subshell above can't export vars)
if ! grep -q 'model_name: claude-opus-4.6$' "$CONFIG_FILE" 2>/dev/null; then
    echo "" >> "$CONFIG_FILE"
    cat >> "$CONFIG_FILE" <<EOF

  - model_name: claude-opus-4.6
    litellm_params:
      model: github_copilot/claude-opus-4.6-1m
      extra_headers: {"Editor-Version": "vscode/${VSCODE_VERSION}", "Copilot-Integration-Id": "vscode-chat"}
    # Claude Opus 4.6 (Anthropic) - enabled (manually added)

EOF
fi

# --- 6. Ensure claude-opus-4.7 entry always exists ---
if ! grep -q 'model_name: claude-opus-4-7$' "$CONFIG_FILE" 2>/dev/null; then
    cat >> "$CONFIG_FILE" <<EOF

  - model_name: claude-opus-4-7
    litellm_params:
      model: github_copilot/claude-opus-4.7-1m-internal
      extra_headers: {"Editor-Version": "vscode/${VSCODE_VERSION}", "Copilot-Integration-Id": "vscode-chat"}
    # Claude Opus 4.7 (Anthropic) - enabled
    # Max tokens: 32000, Context: 200000

EOF
fi

# --- 7. Add footer ---
cat >> "$CONFIG_FILE" <<'FOOTER'

# To use these models:
# 1. Restart LiteLLM: make stop && make start
# 2. Test with: make test
FOOTER

MODEL_COUNT=$(grep -c 'model_name:' "$CONFIG_FILE")
echo "✅ Generated $CONFIG_FILE with $MODEL_COUNT models (vscode/$VSCODE_VERSION)"
