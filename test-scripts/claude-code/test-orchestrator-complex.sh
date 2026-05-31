#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Orchestrator skill — COMPLEX issue test (Path B).
#
# Opens a deliberately COMPLEX GitHub issue (multi-file change across
# directories, architectural decision, body contains "complex") and hands
# it to the orchestrator skill via the same prompt production uses
# (project-management/shared/assistants/claude.py). The orchestrator's
# complexity check should pick Path B and DELEGATE to subagents via the
# Task tool: explore-agent → clarification-agent → implement-agent →
# critique-agent → pr-agent.
#
# After the run, verify in CloudWatch:
#   filter body = "claude_code.tool_result"
#   filter resource.attributes.`session.id` = "<SESSION_ID>"
#   filter attributes.tool_name = "Agent"
#   stats count()
#   → expect >= 1 (typically 4-6: one per delegated stage)
#
# Prerequisites:
#   - All stacks deployed (npx cdk deploy --all)
#   - AWS credentials configured
#   - Python packages: pip install botocore requests
#   - GitHub App installed on the target repository
#   - gh CLI authenticated
#
# Usage:
#   ./test-orchestrator-complex.sh <owner/repo> [session-id]
# ═══════════════════════════════════════════════════════════════════════════

REPO="${1:?Usage: ./test-orchestrator-complex.sh <owner/repo> [session-id]}"
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

SESSION_ID="${2:-test-orch-complex-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p)}"

echo "Runtime ARN: $RUNTIME_ARN"
echo "Region:      $REGION"
echo "Repo:        $OWNER/$REPO_NAME"
echo "Session ID:  $SESSION_ID"
echo "Path:        B (COMPLEX — Task subagents expected)"
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
# Step 1: Create a COMPLEX GitHub issue
# - Multiple files across different directories
# - Architectural decisions required (new patterns)
# - Body contains the literal word "complex" (orchestrator's COMPLEX trigger)
# ═══════════════════════════════════════════════════════════════════════════
echo "=== Step 1: Create COMPLEX GitHub issue ==="
ISSUE_TITLE="feat: Add structured logging and a docs/architecture.md (complex multi-file change)"
ISSUE_BODY="## Specification

This is a complex change touching multiple files across different directories
and requiring an architectural decision.

### Required changes

1. **Add a new docs/architecture.md** at the repo root summarizing the
   high-level architecture. Use H2 headings: Overview, Components, Data Flow,
   Deployment.

2. **Update README.md** to add a new \"## Architecture\" section that links
   to docs/architecture.md.

3. **Update CONTRIBUTING.md** (or create one if missing) to include a section
   pointing reviewers at docs/architecture.md when changes affect more than
   one component.

### Architectural decision

Pick ONE of the two formats for docs/architecture.md and apply it consistently:
  (a) prose-only narrative
  (b) C4-style components with mermaid diagrams

Document the choice in the file's first paragraph.

### Constraints

- All three files must be touched in the same PR.
- Keep each file under 200 lines.
- No code changes outside docs/, README.md, and CONTRIBUTING.md."

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
# Same prompt + allowedTools as production. Path B will fire because the
# spec contains "complex" and touches multiple files across directories.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 6: Run orchestrator skill (Path B — COMPLEX) ==="
echo "    Issue: https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "    Expected: Path B → 4-6 Task subagent calls (explore, clarification, implement, critique, pr)"
echo ""
ESCAPED_TITLE="${ISSUE_TITLE//\"/\\\\\"}"
PROMPT="Follow the orchestrator skill for issue #${ISSUE_NUMBER} (\\\"${ESCAPED_TITLE}\\\"). Owner: ${OWNER}, Repo: ${REPO_NAME}."
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"${PROMPT}\" --allowedTools \"mcp__gateway__*,Read,Write,Edit,Bash,Task,ToolSearch\" < /dev/null 2>&1 || true'" 1500

echo ""
echo "=== Done ==="
echo "Issue:    https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "PRs:      https://github.com/$OWNER/$REPO_NAME/pulls"
echo "Session:  $SESSION_ID"
echo ""
echo "Verify Path B (subagents fired) with these CloudWatch Logs Insights queries:"
echo ""
echo "  # 1) Count Task subagent calls (should be >= 1, typically 4-6)"
echo "  fields attributes.tool_name as tool"
echo "  | filter @logStream = \"otel-rt-logs\""
echo "  | filter body = \"claude_code.tool_result\""
echo "  | filter resource.attributes.\`session.id\` = \"$SESSION_ID\""
echo "  | filter tool = \"Agent\""
echo "  | stats count() as task_subagents"
echo ""
echo "  # 2) Timeline of every Task subagent invocation"
echo "  fields @timestamp, attributes.success as ok, attributes.duration_ms as ms"
echo "  | filter @logStream = \"otel-rt-logs\""
echo "  | filter body = \"claude_code.tool_result\""
echo "  | filter resource.attributes.\`session.id\` = \"$SESSION_ID\""
echo "  | filter attributes.tool_name = \"Task\""
echo "  | sort @timestamp asc"
