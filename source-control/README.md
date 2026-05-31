# Source Control

> [!IMPORTANT]
> This sample is in preview and under active development.

MCP servers that provide code operations (create branches, push files, open pull requests, read files). The coding assistant uses these tools through the AgentCore Gateway to interact with repositories without holding credentials directly.

## Existing Implementations

| Platform | Directory | Status |
|----------|-----------|--------|
| GitHub | [`github/`](./github/) | Production |
| GitLab | — | Planned |

## Architecture

Each source control integration is an MCP server container that:
1. Starts at container boot and generates a short-lived platform token
2. Runs an MCP-compatible HTTP server on port 8000
3. Injects the token into every upstream request (the gateway and assistant never see credentials)

```
Coding Assistant → Gateway → Source Control MCP Server → Platform API (GitHub/GitLab)
                              (injects auth token)
```

## Useful MCP Tools

Tools that a source control MCP server typically exposes:

| Tool | Description |
|------|-------------|
| `create_branch` | Create a feature branch from the default branch |
| `push_files` | Stage files and push a commit |
| `create_pull_request` | Open a pull request with title and body |
| `get_file_contents` | Read a file at a given ref |
| `list_commits` | List recent commits on a branch |
| `list_branches` | List available branches |
| `search_code` | Search repository code by query |

## Adding a New Source Control Platform

### Step 1: Create the directory

```
source-control/<platform>/
└── mcp/
    ├── main.py          # MCP server + auth proxy
    ├── Dockerfile       # Container image
    ├── entrypoint.sh    # Startup script
    └── pyproject.toml   # Dependencies (or requirements.txt)
```

### Step 2: Implement the MCP server

The GitHub implementation ([`github/mcp/main.py`](./github/mcp/main.py)) uses a proxy pattern: it runs the official GitHub MCP server binary and injects auth tokens into each request.

Token generation pattern:

```python
def get_platform_token():
    """Generate a short-lived token from credentials in Secrets Manager."""
    sm = boto3.client("secretsmanager", region_name=region)
    secret = sm.get_secret_value(SecretId=os.environ["PRIVATE_KEY_SECRET_ARN"])
    private_key = secret["SecretString"].encode()

    # Platform-specific token exchange
    # GitHub: JWT → installation token (1 hour)
    # GitLab: OAuth client credentials → access token
    now = int(time.time())
    payload = {"iat": now - 60, "exp": now + 600, "iss": client_id}
    jwt_token = jwt.encode(payload, private_key, algorithm="RS256")

    # Exchange JWT for short-lived token
    url = f"https://api.github.com/app/installations/{installation_id}/access_tokens"
    req = urllib.request.Request(url, method="POST", headers={
        "Authorization": f"Bearer {jwt_token}",
        "Accept": "application/vnd.github+json",
    })
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())["token"]
```

The proxy forwards all requests to the upstream MCP server with the token injected:

```python
class ProxyHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        req = urllib.request.Request(UPSTREAM_URL, data=body, method="POST")
        req.add_header("Authorization", f"Bearer {PLATFORM_TOKEN}")
        req.add_header("mcp-session-id", self.headers.get("mcp-session-id", ""))
        with urllib.request.urlopen(req, timeout=120) as resp:
            self.send_response(resp.status)
            self.end_headers()
            self.wfile.write(resp.read())
```

### Step 3: Write the Dockerfile

Follow the AgentCore Runtime service contract:

```dockerfile
FROM ghcr.io/astral-sh/uv:python3.13-bookworm-slim

WORKDIR /app
RUN useradd -m -u 1000 bedrock_agentcore

# Install platform MCP server binary (e.g., Go binary for GitHub)
# RUN curl -L https://github.com/github/github-mcp-server/releases/download/... -o /usr/local/bin/github-mcp-server

COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project
COPY --chown=bedrock_agentcore:bedrock_agentcore . .
RUN uv sync --frozen --no-dev

USER bedrock_agentcore
EXPOSE 8080 8000 9000
CMD ["python", "main.py"]
```

### Step 4: Add CDK stack

Create `lib/nested/source-control-stack.ts` (or add a conditional branch to the existing one). The key constructs:

```typescript
import { McpServer } from "../constructs/runtime/mcp-server";
import { registerGatewayTarget, buildRuntimeEndpoint } from "../utils";

const mcp = new McpServer(this, "McpServer", {
  name: `${config.project}_gitlab_code`,
  codePath: "./source-control/gitlab/mcp",
  vpc, securityGroup,
  protocol: "MCP",
  maxLifetime: 3300,
  environmentVariables: {
    // Platform-specific credentials
  },
});

registerGatewayTarget(this, "GatewayTarget", gatewayId, {
  name: "gitlab-code",
  mcpServerEndpoint: buildRuntimeEndpoint(config.region, mcp.runtimeArn),
  credentialProviderType: "GATEWAY_IAM_ROLE",
  iamService: "bedrock-agentcore",
  allowedRequestHeaders: ["mcp-session-id"],
});
```

See [`lib/nested/source-control-stack.ts`](../lib/nested/source-control-stack.ts) for the complete GitHub implementation.

### Step 5: Configure

```yaml
sourceControl:
  type: gitlab
  gitlab:
    projectToken: ""
    # Platform-specific credentials
```

### Credential Pattern

- Store long-lived credentials (private keys, OAuth secrets) in AWS Secrets Manager
- Generate short-lived tokens at container startup
- Set container `maxLifetime` shorter than token expiry (e.g., 55 min for 60 min tokens)
- The gateway and coding assistant never see credentials — only the MCP server container accesses them
