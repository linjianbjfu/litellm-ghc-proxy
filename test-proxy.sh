#!/bin/bash
echo "Testing proxy connection..."
curl -X POST http://localhost:4000/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $(grep LITELLM_MASTER_KEY .env | cut -d'=' -f2 | tr -d '\"')" \
  -d '{"model": "claude-opus-4.5", "messages": [{"role": "user", "content": "Hello"}]}'
