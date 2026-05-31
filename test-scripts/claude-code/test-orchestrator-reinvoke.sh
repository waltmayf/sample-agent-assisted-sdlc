#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Orchestrator skill — RE-INVOCATION test.
#
# Reuses a previously-completed session, posts a fresh comment on the issue,
# rotates .dev-claude/current/ into .dev-claude/invocation-1/, then re-invokes
# the orchestrator. Exercises the re-invocation skill path:
#
#   explore-agent reads invocation-1/pr.md + new issue/PR comments,
#   writes feedback.md, re-explores incorporating the feedback.
#
# Optionally runs `claude --continue` to also reuse Claude's conversation
# memory from the prior invocation.
#
# Prerequisites:
#   - The session must already exist and be warm (run test-orchestrator-{simple|complex}.sh first)
#   - The issue must already have an open PR from the previous run
#
# Usage:
#   ./test-orchestrator-reinvoke.sh <owner/repo> <issue-number> <existing-session-id> [comment-body]
#
# Example (continuing from your complex test):
#   ./test-orchestrator-reinvoke.sh <owner/repo> <issue-number> <session-id> \
#     "The architecture.md is hard-wrapped at 70 chars. Please rewrite as one paragraph per line so future edits don't churn the diff."
# ═══════════════════════════════════════════════════════════════════════════

REPO="${1:?Usage: ./test-orchestrator-reinvoke.sh <owner/repo> <issue-number> <session-id> [comment-body]}"
ISSUE_NUMBER="${2:?missing issue-number}"
SESSION_ID="${3:?missing session-id (must match a prior test session)}"
COMMENT_BODY="${4:-Please re-run with the new markdown formatting rules: do not hard-wrap paragraphs, write one paragraph per line. Apply this to the existing files in this PR.}"

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

echo "Runtime ARN:  $RUNTIME_ARN"
echo "Region:       $REGION"
echo "Repo:         $OWNER/$REPO_NAME"
echo "Issue:        #$ISSUE_NUMBER"
echo "Session ID:   $SESSION_ID  (reusing existing session)"
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
# Step 1: Confirm the session is warm and the workspace still exists
# ═══════════════════════════════════════════════════════════════════════════
echo "=== Step 1: Confirm session warm + workspace exists ==="
exec_cmd "sh -c 'ls -la /mnt/workplace/gitproject/.dev-claude/ 2>&1 || echo NO_WORKSPACE'"

# ═══════════════════════════════════════════════════════════════════════════
# Step 2: Post a new comment on the issue (the user feedback)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 2: Post feedback comment on issue #$ISSUE_NUMBER ==="
echo "Comment body:"
echo "  $COMMENT_BODY"
echo ""
gh issue comment "$ISSUE_NUMBER" --repo "$OWNER/$REPO_NAME" --body "$COMMENT_BODY"

# ═══════════════════════════════════════════════════════════════════════════
# Step 3: Rotate current/ -> invocation-1/ inside the runtime workspace
# Per the orchestrator skill's RE-INVOCATION DETECTION block:
#   "If ./.dev-claude/invocation-1/ exists ... this is a re-invocation"
# We physically move the previous artifacts so the skill's detection fires.
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 3: Rotate .dev-claude/current/ -> .dev-claude/invocation-1/ ==="
exec_cmd "sh -c '
  cd /mnt/workplace/gitproject &&
  if [ -d .dev-claude/invocation-1 ]; then
    echo invocation-1 already exists, moving aside
    mv .dev-claude/invocation-1 .dev-claude/invocation-1-prev-\$(date +%s)
  fi &&
  if [ -L .dev-claude/current ]; then
    echo current was already a symlink, dereferencing
    rm .dev-claude/current
  elif [ -d .dev-claude/current ]; then
    mv .dev-claude/current .dev-claude/invocation-1
  fi &&
  mkdir -p .dev-claude/current &&
  echo === after rotation === &&
  ls -la .dev-claude/'"

# ═══════════════════════════════════════════════════════════════════════════
# Step 4: Refresh issue.json with the new comment so the orchestrator sees it
# (Real production would re-fetch via the connector; we sync from gh CLI here)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 4: Refresh issue.json with all comments ==="
ISSUE_DATA=$(gh issue view "$ISSUE_NUMBER" --repo "$OWNER/$REPO_NAME" --json number,title,body,comments)
ISSUE_TITLE=$(echo "$ISSUE_DATA" | jq -r .title)
ISSUE_BODY=$(echo "$ISSUE_DATA" | jq -r .body)

ISSUE_JSON_B64=$(jq -n \
  --arg o "$OWNER" --arg r "$REPO_NAME" --arg n "$ISSUE_NUMBER" \
  --arg t "$ISSUE_TITLE" --arg b "$ISSUE_BODY" \
  --argjson c "$(echo "$ISSUE_DATA" | jq '.comments')" \
  '{repo_owner: $o, repo_name: $r, issue_number: ($n | tonumber), issue_title: $t, issue_body: $b, issue_author: "test-runner", issue_comments: $c}' | base64 | tr -d '\n')

exec_cmd "sh -c 'echo $ISSUE_JSON_B64 | base64 -d > /mnt/workplace/gitproject/.dev-claude/issue.json && echo OK'"

# OTEL_RESOURCE_ATTRIBUTES export — keep continuity with the same session id
OTEL_PREFIX="export OTEL_RESOURCE_ATTRIBUTES=\"\${OTEL_RESOURCE_ATTRIBUTES:+\$OTEL_RESOURCE_ATTRIBUTES,}session.id=${SESSION_ID},gen_ai.conversation.id=${SESSION_ID}\" && "

# ═══════════════════════════════════════════════════════════════════════════
# Step 5: Re-invoke the orchestrator skill with --continue
# --continue reuses Claude's conversation memory from the prior invocation
# (same session container, so the chat history is on disk in ~/.claude/)
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "=== Step 5: Re-invoke orchestrator (--continue, RE-INVOCATION path) ==="
echo "    Issue: https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "    Expected: explore-agent detects invocation-1/, writes feedback.md,"
echo "              implement-agent applies the new feedback, pr-agent updates"
echo "              the existing PR (force-push or new commit on the same branch)."
echo ""
ESCAPED_TITLE="${ISSUE_TITLE//\"/\\\\\"}"
PROMPT="Re-invocation for issue #${ISSUE_NUMBER} (\\\"${ESCAPED_TITLE}\\\"). Follow the orchestrator skill. Previous artifacts are in ./.dev-claude/invocation-1/. New feedback was posted on the issue and PR; read the latest comments and incorporate the feedback into the existing branch feat/issue-${ISSUE_NUMBER}. Owner: ${OWNER}, Repo: ${REPO_NAME}."
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --continue --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"${PROMPT}\" --allowedTools \"mcp__gateway__*,Read,Write,Edit,Bash,Task,ToolSearch\" < /dev/null 2>&1 || true'" 1500

echo ""
echo "=== Done ==="
echo "Issue:    https://github.com/$OWNER/$REPO_NAME/issues/$ISSUE_NUMBER"
echo "PRs:      https://github.com/$OWNER/$REPO_NAME/pulls"
echo "Session:  $SESSION_ID"
echo ""
echo "Verify re-invocation worked with these CloudWatch Logs Insights queries:"
echo ""
echo "  # Confirm a fresh user_prompt fired in this session (continuation, not new session)"
echo "  fields @timestamp, attributes.session.id as claude_uuid"
echo "  | filter @logStream = \"otel-rt-logs\""
echo "  | filter resource.attributes.\`session.id\` = \"$SESSION_ID\""
echo "  | filter body = \"claude_code.user_prompt\""
echo "  | sort @timestamp asc"
echo ""
echo "  # Subagent invocations from THIS run only (filter by recent timestamp)"
echo "  fields @timestamp, attributes.tool_name as tool, attributes.duration_ms as ms"
echo "  | filter @logStream = \"otel-rt-logs\""
echo "  | filter resource.attributes.\`session.id\` = \"$SESSION_ID\""
echo "  | filter body = \"claude_code.tool_result\""
echo "  | filter tool = \"Agent\""
echo "  | sort @timestamp desc"
echo "  | limit 20"
