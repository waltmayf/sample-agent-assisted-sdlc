#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════
# Validates the deployed coding assistant can connect
# to the AgentCore Gateway and discover MCP tools.
#
# Prerequisites:
#   - All stacks deployed (npx cdk deploy --all)
#   - AWS credentials configured
#   - Python packages: pip install botocore requests
#
# Usage:
#   ./test-gateway.sh [session-id]
#
# Pass an existing session-id to reuse a warm session.
# ═══════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STACK_NAME=$(grep "^project:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')-assistant
RUNTIME_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CodingAssistantRuntimeArn'].OutputValue" \
  --output text 2>/dev/null)

if [ -z "$RUNTIME_ARN" ] || [ "$RUNTIME_ARN" == "None" ]; then
  echo "ERROR: Could not find CodingAssistantRuntimeArn in stack outputs."
  echo "Make sure the stack is deployed: npx cdk deploy --all"
  exit 1
fi

REGION=$(grep "^region:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')
SESSION_ID="${1:-test-session-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p)}"

echo "Runtime ARN: $RUNTIME_ARN"
echo "Region: $REGION"
echo "Session ID: $SESSION_ID"
echo ""

# Executes a shell command inside the AgentCore Runtime session.
# Uses SigV4-signed HTTP streaming to the commands API.
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

echo "=== Step 1: Verify session storage ==="
exec_cmd "ls -la /mnt/workplace"

echo ""
echo "=== Step 2: Verify plugins mount ==="
exec_cmd "ls -la /mnt/plugins"

echo ""
echo "=== Step 3: Check .mcp.json ==="
exec_cmd "cat /mnt/plugins/.mcp.json"

echo ""
echo "=== Step 4: Check gateway-iam-proxy ==="
exec_cmd "sh -c 'ls /mnt/plugins/gateway-iam-proxy/node_modules/@modelcontextprotocol && echo PROXY OK || echo PROXY MISSING'"

echo ""
echo "=== Step 5: Setup workspace ==="
exec_cmd "sh -c 'mkdir -p /mnt/workplace/gitproject/.dev-claude /mnt/workplace/gitproject/.claude && cp -r /mnt/plugins/skills /mnt/plugins/hooks /mnt/plugins/.claude-plugin /mnt/plugins/settings.json /mnt/plugins/.mcp.json /mnt/workplace/gitproject/ && cp /mnt/workplace/gitproject/settings.json /mnt/workplace/gitproject/.claude/settings.json && chmod +x /mnt/workplace/gitproject/hooks/*.sh && echo OK'"

# OTEL_RESOURCE_ATTRIBUTES export injected before each `claude` call so its
# native OTel SDK stamps every span/metric with the runtime session id.
# Appended (not overwritten) — AgentCore injects cloud.* attrs at boot.
OTEL_PREFIX="export OTEL_RESOURCE_ATTRIBUTES=\"\${OTEL_RESOURCE_ATTRIBUTES:+\$OTEL_RESOURCE_ATTRIBUTES,}session.id=${SESSION_ID},gen_ai.conversation.id=${SESSION_ID}\" && "

echo ""
echo "=== Step 6: Verify copied files ==="
exec_cmd "sh -c 'find /mnt/workplace/gitproject -maxdepth 2 -type f'"

echo ""
echo "=== Step 7: Test gateway connection ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude mcp list 2>&1 || true'" 60

echo ""
echo "=== Step 8: List MCP tools ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"List all available MCP tools. Show only the tool names grouped by server.\" --allowedTools \"mcp__gateway__*,ToolSearch\" < /dev/null 2>&1 || true'" 120

echo ""
echo "=== Step 9: Invoke MCP tool ==="
exec_cmd "sh -c 'cd /mnt/workplace/gitproject && ${OTEL_PREFIX}claude --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject -p \"Search AWS documentation for Amazon Bedrock AgentCore Runtime using the aws docs search tool. Show the tool you called and the first 3 results with titles and URLs.\" --allowedTools \"mcp__gateway__*,ToolSearch\" < /dev/null 2>&1 || true'" 120

echo ""
echo "=== Done ==="
echo "Session ID: $SESSION_ID (reuse with: ./test-gateway.sh $SESSION_ID)"
