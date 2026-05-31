#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════
# Tests MCP tool operations: create branch, push
# file, and create PR via the gateway.
#
# Prerequisites:
#   - All stacks deployed (npx cdk deploy --all)
#   - AWS credentials configured
#   - Python packages: pip install botocore requests
#   - GitHub App installed on the target repository
#
# Usage:
#   ./test-github-repo.sh <owner/repo> [session-id]
#
# Example:
#   ./test-github-repo.sh myorg/my-app
# ═══════════════════════════════════════════════════

REPO="${1:?Usage: ./test-github-repo.sh <owner/repo> [session-id]}"
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

SESSION_ID="${2:-test-repo-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p)}"
# scope-guard.sh restricts branches to feat/issue-${issue_number}. We pick a
# fresh issue number per run (timestamp) so the branch is unique and the hook
# allows it. project.json below is written with the same number.
ISSUE_NUMBER=$(date +%s)
BRANCH="feat/issue-${ISSUE_NUMBER}"

echo "Runtime ARN: $RUNTIME_ARN"
echo "Region: $REGION"
echo "Repo: $OWNER/$REPO_NAME"
echo "Branch: $BRANCH"
echo "Session ID: $SESSION_ID"
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

arn = sys.argv[1]
region = sys.argv[2]
session_id = sys.argv[3]
command = sys.argv[4]
timeout = int(sys.argv[5])

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

resp = requests.post(
    url,
    params={'qualifier': 'DEFAULT'},
    headers=dict(req.headers),
    data=body,
    timeout=timeout + 30,
    stream=True,
)

if not resp.ok:
    print(f'HTTP {resp.status_code}: {resp.text}', file=sys.stderr)
    sys.exit(1)

stdout_parts, stderr_parts, exit_code = [], [], 0
buf = EventStreamBuffer()
for chunk in resp.iter_content(chunk_size=4096):
    if not chunk:
        continue
    buf.add_data(chunk)
    for ev in buf:
        if not ev.payload:
            continue
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

# ═══════════════════════════════════════════════════
# Step 1: Clone repo into /mnt/workplace/gitproject
# ═══════════════════════════════════════════════════
echo "=== Step 1: Clone repo ==="
exec_cmd "sh -c 'git clone https://github.com/${OWNER}/${REPO_NAME}.git /mnt/workplace/gitproject 2>&1 && echo OK || echo FAILED'"

# ═══════════════════════════════════════════════════
# Step 2: Copy plugin on top + write context
# ═══════════════════════════════════════════════════
echo ""
echo "=== Step 2: Setup workspace ==="
exec_cmd "sh -c 'mkdir -p /mnt/workplace/gitproject/.dev-claude /mnt/workplace/gitproject/.claude && cp -r /mnt/plugins/skills /mnt/plugins/hooks /mnt/plugins/.claude-plugin /mnt/plugins/settings.json /mnt/plugins/.mcp.json /mnt/workplace/gitproject/ && cp /mnt/workplace/gitproject/settings.json /mnt/workplace/gitproject/.claude/settings.json && chmod +x /mnt/workplace/gitproject/hooks/*.sh && echo OK'"

# OTEL_RESOURCE_ATTRIBUTES export injected before each `claude` call so its
# native OTel SDK stamps every span/metric with the runtime session id.
OTEL_PREFIX="export OTEL_RESOURCE_ATTRIBUTES=\"\${OTEL_RESOURCE_ATTRIBUTES:+\$OTEL_RESOURCE_ATTRIBUTES,}session.id=${SESSION_ID},gen_ai.conversation.id=${SESSION_ID}\" && "

# ═══════════════════════════════════════════════════
# Step 3: Write project.json (needed by scope-guard hook)
# ═══════════════════════════════════════════════════
echo ""
echo "=== Step 3: Write context files ==="
ISSUE_JSON=$(jq -n --argjson n "$ISSUE_NUMBER" '{number: $n, title: "Test: MCP tool validation", body: "Automated test", comments: []}')
PROJECT_JSON=$(jq -n --arg owner "$OWNER" --arg repo "$REPO_NAME" --argjson n "$ISSUE_NUMBER" '{owner: $owner, repo: $repo, issue_number: $n}')

exec_cmd "sh -c 'cat > /mnt/workplace/gitproject/.dev-claude/issue.json << '\''JSONEOF'\''
${ISSUE_JSON}
JSONEOF
cat > /mnt/workplace/gitproject/.dev-claude/project.json << '\''JSONEOF'\''
${PROJECT_JSON}
JSONEOF
echo OK'"

# ═══════════════════════════════════════════════════
# Step 4: Create branch via MCP
# ═══════════════════════════════════════════════════
echo ""
echo "=== Step 4: Create branch via MCP ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"Use mcp__gateway__github-code___create_branch to create a branch named ${BRANCH} from ref main in owner ${OWNER} repo ${REPO_NAME}. Show the result.\" --allowedTools \"mcp__gateway__*,ToolSearch\" < /dev/null 2>&1 || true'" 60

# ═══════════════════════════════════════════════════
# Step 5: Push file via MCP
# ═══════════════════════════════════════════════════
echo ""
echo "=== Step 5: Push file via MCP ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"Use mcp__gateway__github-code___push_files to push a file named agentcore-test.txt with content \\\"Hello from AgentCore SDLC pipeline test - $(date -u +%Y-%m-%dT%H:%M:%SZ)\\\" to branch ${BRANCH} in owner ${OWNER} repo ${REPO_NAME} with commit message \\\"test: validate agentcore pipeline\\\". Show the result.\" --allowedTools \"mcp__gateway__*,ToolSearch\" < /dev/null 2>&1 || true'" 60

# ═══════════════════════════════════════════════════
# Step 6: Create PR via MCP
# ═══════════════════════════════════════════════════
echo ""
echo "=== Step 6: Create PR via MCP ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"Use mcp__gateway__github-code___create_pull_request to create a PR in owner ${OWNER} repo ${REPO_NAME} with head ${BRANCH} base main title \\\"test: AgentCore SDLC pipeline validation\\\" and body \\\"Automated test from AgentCore coding assistant runtime via MCP gateway.\\\". Show the result.\" --allowedTools \"mcp__gateway__*,ToolSearch\" < /dev/null 2>&1 || true'" 60

echo ""
echo "=== Done ==="
echo "Check: https://github.com/${OWNER}/${REPO_NAME}/pulls"
echo "Session ID: $SESSION_ID"
