#!/bin/bash
set -e

# Fetch GitHub token from the Token Lambda
TOKEN=$(python3 -c "
import boto3, json, os
client = boto3.client('lambda', region_name=os.environ.get('AWS_REGION', 'us-west-2'))
resp = client.invoke(FunctionName=os.environ['TOKEN_FUNCTION_NAME'])
payload = json.loads(resp['Payload'].read())
body = json.loads(payload['body'])
print(body['token'])
")

export GITHUB_PERSONAL_ACCESS_TOKEN="$TOKEN"

exec /usr/local/bin/github-mcp-server http \
  --port 8000 \
  --toolsets "${GITHUB_TOOLSETS:-repos,issues,pull_requests,context,users}"
