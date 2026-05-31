#!/bin/bash
# Scans content being written or pushed for credential patterns.
# Exit 2 = block, Exit 0 = allow.

INPUT=$(cat)

# Extract content from tool_input (handles Write, Edit, push_files)
CONTENT=$(echo "$INPUT" | jq -r '
  .tool_input.content //
  .tool_input.new_string //
  (.tool_input.files // [] | .[].content // empty) //
  empty' 2>/dev/null)

if [ -z "$CONTENT" ]; then
  exit 0
fi

# Check for credential patterns
if echo "$CONTENT" | grep -qE '(AKIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |DSA )?PRIVATE KEY|ghp_[a-zA-Z0-9]{36}|gho_[a-zA-Z0-9]{36}|ghs_[a-zA-Z0-9]{36}|github_pat_[a-zA-Z0-9_]{22,}|sk-[a-zA-Z0-9]{20,}|xox[bp]-[a-zA-Z0-9-]{10,}|aws_secret_access_key|AWS_SECRET_ACCESS_KEY)'; then
  echo "BLOCKED: Content appears to contain credentials or secrets. Remove sensitive data before writing."
  exit 2
fi

exit 0
