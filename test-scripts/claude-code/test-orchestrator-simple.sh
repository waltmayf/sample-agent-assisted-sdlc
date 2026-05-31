#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Orchestrator skill — SIMPLE issue test (Path A).
#
# Opens a deliberately SIMPLE GitHub issue (single-file change, unambiguous,
# no architectural decisions) and hands it to the orchestrator skill via
# the same prompt production uses (project-management/shared/assistants/
# claude.py). The orchestrator's complexity check should pick Path A and
# handle the pipeline inline — NO Task subagents fire.
#
# After the run, verify in CloudWatch:
#   filter body = "claude_code.tool_result"
#   filter resource.attributes.`session.id` = "<SESSION_ID>"
#   filter attributes.tool_name = "Task"
#   stats count()
#   → expect 0
#
# Prerequisites:
#   - All stacks deployed (npx cdk deploy --all)
#   - AWS credentials configured
#   - Python packages: pip install botocore requests
#   - GitHub App installed on the target repository
#   - gh CLI authenticated
#
# Usage:
#   ./test-orchestrator-simple.sh <owner/repo> [session-id]
# ═══════════════════════════════════════════════════════════════════════════

REPO="${1:?Usage: ./test-orchestrator-simple.sh <owner/repo> [session-id]}"
OWNER="${REPO%%/*}"
REPO_NAME="${REPO##*/}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STACK_NAME=$(grep "^project:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')
REGION=$(grep "^region:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')

RUNTIME_ARN=$(aws cloudformation describe-stacks \
  --stack-name "${STACK_NAME}-assistant" \
  --query "Stacks[0].Outputs[?OutputKey=='CodingAssistantRuntimeArn'].OutputValue" \
  --output text --region "$REGION" 2>/dev/null)

if [ -z "$RUNTIME_ARN" ] || [ "$RUNTIME_ARN" == "None" ]; then
  echo "ERROR: Could not find CodingAssistantRuntimeArn. Deploy first: npx cdk deploy --all"
  exit 1
fi

SESSION_ID="${2:-test-orch-simple-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p)}"

echo "Runtime ARN: $RUNTIME_ARN"
echo "Region:      $REGION"
echo "Repo:        $OWNER/$REPO_NAME"
echo "Session ID:  $SESSION_ID"
echo "Path:        A (SIMPLE — no subagents expected)"
echo ""

exec_cmd() {
  local cmd="$1"
  local timeout="${2:-120}"
  python3 - "$RUNTIME_ARN" "$REGION" "$SESSION_ID" "$cmd" "$timeout" << 'PYTHON_EOF'
import json, urllib.parse, sys
import botocore.session
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from botocore.eventstream import EventStreamBuffer
import requests

arn, region, session_id, command, timeout = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
escaped_arn = urllib.parse.quote(arn, safe='')
url = f'https://bedrock-agentcore.{region}.amazonaws.com/runtimes/{escaped_arn}/commands'
body = json.dumps({'command': command, 'timeout': timeout}).encode()
headers = {
    'Content-Type': 'application/json',
    'Accept': 'application/vnd.amazon.eventstream',
    'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id': session_id,
}
session = botocore.session.get_session()
creds = session.get_credentials().get_frozen_credentials()
req = AWSRequest(method='POST', url=f'{url}?qualifier=DEFAULT', data=body, headers=headers)
SigV4Auth(creds, 'bedrock-agentcore', region).add_auth(req)

resp = requests.post(url, params={'qualifier': 'DEFAULT'}, headers=dict(req.headers), data=body, timeout=timeout + 30, stream=True)
if not resp.ok:
    print(f'HTTP {resp.status_code}: {resp.text}', file=sys.stderr)
    sys.exit(1)

stdout_parts, stderr_parts, exit_code = [], [], 0
buf = EventStreamBuffer()
for chunk in resp.iter_content(chunk_size=4096):
    if not chunk: continue
    buf.add_data(chunk)
    for ev in buf:
        if not ev.payload: continue
        try:
            decoded = json.loads(ev.payload)
        except json.JSONDecodeError:
            continue
        inner = decoded.get('chunk') if isinstance(decoded, dict) else None
        event = inner if isinstance(inner, dict) else decoded
        if 'contentDelta' in event:
            d = event['contentDelta']
            if 'stdout' in d: stdout_parts.append(d['stdout'])
            if 'stderr' in d: stderr_parts.append(d['stderr'])
        elif 'contentStop' in event:
            exit_code = int(event['contentStop'].get('exitCode', 0))

out = ''.join(stdout_parts)
err = ''.join(stderr_parts)
if out: print(out, end='')
if err: print(err, end='', file=sys.stderr)
sys.exit(exit_code)
PYTHON_EOF
}

# ═══════════════════════════════════════════════════════════════════════════
# Step 1: Create a SIMPLE GitHub issue
# Single file. Unambiguous spec. Small bug-fix-style change.
# ═══════════════════════════════════════════════════════════════════════════
echo "=== Step 1: Create SIMPLE GitHub issue ==="
ISSUE_TITLE="docs: Add a one-line project tagline to README.md"
ISSUE_BODY="## Specification

Add a single italicized tagline as the FIRST line beneath the H1 heading in
README.md (and only that file). The tagline must be exactly:

  *Production-grade infrastructure as code, simplified.*

No other changes. No new files. No formatting changes elsewhere in the README.
This is a one-file edit, no design decisions, no ambiguity."

gh label create "agent:start" --repo "$OWNER/$REPO_NAME" --description "Triggers the autonomous coding agent" --color "7057ff" 2>/dev/null || true

ISSUE_URL=$(gh issue create \
  --repo "$OWNER/$REPO_NAME" \
  --title "$ISSUE_TITLE" \
  --body "$ISSUE_BODY" \
  --label "agent:start" 2>&1) || true

ISSUE_NUMBER=$(echo "$ISSUE_URL" | grep -oE '[0-9]+$' || true)
if [ -z "$ISSUE_NUMBER" ]; then
  echo "ERROR: Failed to create issue."
  echo "gh output: $ISSUE_URL"
  exit 1
fi

echo "Created issue #$ISSUE_NUMBER: $ISSUE_TITLE"
echo "https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Clone repo
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 2: Clone repo ==="
exec_cmd "sh -c 'rm -rf /mnt/workplace/gitproject && git clone https://github.com/${OWNER}/${REPO_NAME}.git /mnt/workplace/gitproject 2>&1 && echo OK || echo FAILED'"

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Copy plugin on top of cloned repo
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 3: Setup workspace ==="
exec_cmd "sh -c 'mkdir -p /mnt/workplace/gitproject/.dev-claude /mnt/workplace/gitproject/.claude && cp -r /mnt/plugins/skills /mnt/plugins/hooks /mnt/plugins/.claude-plugin /mnt/plugins/settings.json /mnt/plugins/.mcp.json /mnt/workplace/gitproject/ && cp /mnt/workplace/gitproject/settings.json /mnt/workplace/gitproject/.claude/settings.json && chmod +x /mnt/workplace/gitproject/hooks/*.sh && echo OK'"

# OTEL_RESOURCE_ATTRIBUTES export injected before each `claude` call so its
# native OTel SDK stamps every event with the runtime session id.
OTEL_PREFIX="export OTEL_RESOURCE_ATTRIBUTES=\"\${OTEL_RESOURCE_ATTRIBUTES:+\$OTEL_RESOURCE_ATTRIBUTES,}session.id=${SESSION_ID},gen_ai.conversation.id=${SESSION_ID}\" && "

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Write context files
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 4: Write context files ==="
# Use base64 to round-trip JSON safely — bodies with quotes / backticks /
# newlines collide with the heredoc-in-`sh -c` quoting otherwise.
ISSUE_JSON_B64=$(jq -n --arg o "$OWNER" --arg r "$REPO_NAME" --arg n "$ISSUE_NUMBER" \
  --arg t "$ISSUE_TITLE" --arg b "$ISSUE_BODY" \
  '{repo_owner: $o, repo_name: $r, issue_number: ($n | tonumber), issue_title: $t, issue_body: $b, issue_author: "test-runner", issue_comments: []}' | base64 | tr -d '\n')
PROJECT_JSON_B64=$(jq -n --arg o "$OWNER" --arg r "$REPO_NAME" --arg n "$ISSUE_NUMBER" \
  '{owner: $o, repo: $r, issue_number: ($n | tonumber)}' | base64 | tr -d '\n')

exec_cmd "sh -c 'echo ${ISSUE_JSON_B64} | base64 -d > /mnt/workplace/gitproject/.dev-claude/issue.json && echo ${PROJECT_JSON_B64} | base64 -d > /mnt/workplace/gitproject/.dev-claude/project.json && echo OK'"

# ═══════════════════════════════════════════════════════════════════════════
# Step 4b: Create invocation-1/ + symlink current → invocation-1
# Mirrors project-management/shared/assistants/base.py setup_workspace
# (lines 52-60). The orchestrator skill's RE-INVOCATION DETECTION depends
# on .dev-claude/invocation-1/ existing.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 4b: Init invocation-1 + current symlink ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject/.dev-claude && N=\$(ls -d invocation-* 2>/dev/null | wc -l) && N=\$((N + 1)) && mkdir -p invocation-\$N && ln -sfn invocation-\$N current && ls -la'"

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Verify MCP connection
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 5: Verify MCP connection ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude mcp list 2>&1 || true'" 60

# ═══════════════════════════════════════════════════════════════════════════
# Step 6: Hand the issue to the orchestrator skill
# Same prompt + allowedTools as production (project-management/shared/
# assistants/claude.py). Path A means inline execution, no subagents.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 6: Run orchestrator skill (Path A — SIMPLE) ==="
echo "    Issue: https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "    Expected: Path A → 0 Task subagent calls"
echo ""
ESCAPED_TITLE="${ISSUE_TITLE//\"/\\\\\"}"
PROMPT="Follow the orchestrator skill for issue #${ISSUE_NUMBER} (\\\"${ESCAPED_TITLE}\\\"). Owner: ${OWNER}, Repo: ${REPO_NAME}."
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"${PROMPT}\" --allowedTools \"mcp__gateway__*,Read,Write,Edit,Bash,Task,ToolSearch\" < /dev/null 2>&1 || true'" 900

echo ""
echo "=== Done ==="
echo "Issue:    https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "PRs:      https://github.com/$OWNER/$REPO_NAME/pulls"
echo "Session:  $SESSION_ID"
echo ""
echo "Verify Path A (no subagents) with this CloudWatch Logs Insights query:"
echo ""
echo "  fields attributes.tool_name as tool"
echo "  | filter @logStream = \"otel-rt-logs\""
echo "  | filter body = \"claude_code.tool_result\""
echo "  | filter resource.attributes.\`session.id\` = \"$SESSION_ID\""
echo "  | filter tool = \"Agent\""
echo "  | stats count() as task_subagents"
echo ""
echo "Expected: task_subagents = 0"
