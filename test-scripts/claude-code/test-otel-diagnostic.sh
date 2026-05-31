#!/bin/bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# OTel Diagnostic — inspect collector and telemetry state inside the runtime.
#
# Checks OTEL_* env vars, verifies the collector is listening on 4318/4317,
# lists listening ports, and shows running processes.
#
# Prerequisites:
#   - All stacks deployed (npx cdk deploy --all)
#   - AWS credentials configured
#   - Python packages: pip install botocore requests
#
# Usage:
#   ./test-otel-diagnostic.sh
# ═══════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

STACK_NAME=$(grep "^project:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')-assistant
REGION=$(grep "^region:" "$PROJECT_ROOT/sdlc-config.yaml" | awk '{print $2}')
RUNTIME_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='CodingAssistantRuntimeArn'].OutputValue" \
  --output text --region "$REGION" 2>/dev/null)

SESSION_ID="test-otel-$(date +%s)-$(head -c 16 /dev/urandom | xxd -p)"

echo "Runtime ARN: $RUNTIME_ARN"
echo "Session ID: $SESSION_ID"
echo ""

exec_cmd() {
  local cmd="$1"
  local timeout="${2:-30}"
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
headers = {'Content-Type': 'application/json', 'Accept': 'application/vnd.amazon.eventstream', 'X-Amzn-Bedrock-AgentCore-Runtime-Session-Id': session_id}
session = botocore.session.get_session()
creds = session.get_credentials().get_frozen_credentials()
req = AWSRequest(method='POST', url=f'{url}?qualifier=DEFAULT', data=body, headers=headers)
SigV4Auth(creds, 'bedrock-agentcore', region).add_auth(req)
resp = requests.post(url, params={'qualifier': 'DEFAULT'}, headers=dict(req.headers), data=body, timeout=timeout+30, stream=True)
if not resp.ok: print(f'HTTP {resp.status_code}: {resp.text}', file=sys.stderr); sys.exit(1)
buf = EventStreamBuffer()
for chunk in resp.iter_content(chunk_size=4096):
    if not chunk: continue
    buf.add_data(chunk)
    for ev in buf:
        if not ev.payload: continue
        try:
            decoded = json.loads(ev.payload)
            inner = decoded.get('chunk') if isinstance(decoded, dict) else None
            event = inner if isinstance(inner, dict) else decoded
            if 'contentDelta' in event:
                d = event['contentDelta']
                if 'stdout' in d: print(d['stdout'], end='')
                if 'stderr' in d: print(d['stderr'], end='', file=sys.stderr)
        except: continue
PYTHON_EOF
}

echo "=== OTEL Environment Variables ==="
exec_cmd "sh -c 'env | grep -i otel | sort'"

echo ""
echo "=== Agent/Observability Environment Variables ==="
exec_cmd "sh -c 'env | grep -i -E \"agent|observ|telemetry\" | sort'"

echo ""
echo "=== Test OTLP Collector on localhost:4318 ==="
exec_cmd "sh -c 'curl -s -o /dev/null -w \"%{http_code}\" http://localhost:4318/v1/traces -X POST -H \"Content-Type: application/json\" -d \"{}\" 2>&1 || echo NO_COLLECTOR_4318'"

echo ""
echo "=== Test OTLP Collector on localhost:4317 ==="
exec_cmd "sh -c 'curl -s -o /dev/null -w \"%{http_code}\" http://localhost:4317 2>&1 || echo NO_COLLECTOR_4317'"

echo ""
echo "=== Listening ports ==="
exec_cmd "sh -c 'ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null || echo no_ss_or_netstat'"

echo ""
echo "=== Running processes ==="
exec_cmd "ps aux"

echo ""
echo "=== Done ==="
