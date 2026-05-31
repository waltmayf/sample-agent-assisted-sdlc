# Contributing Guidelines

Thank you for your interest in contributing to our project. Whether it's a bug report, new feature, correction, or additional
documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary
information to effectively respond to your bug report or contribution.


## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already
reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The version of our code being used
* Any modifications you've made relevant to the bug
* Anything unusual about your environment or deployment


## Contributing via Pull Requests
Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss any significant work - we would hate for your time to be wasted.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local tests pass.
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering any default questions in the pull request interface.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and
[creating a pull request](https://help.github.com/articles/creating-a-pull-request/).


## Finding contributions to work on
Looking at the existing issues is a great way to find something to contribute on. As our projects, by default, use the default GitHub issue labels (enhancement/bug/duplicate/help wanted/invalid/question/wontfix), looking at any 'help wanted' issues is a great place to start.


## Code of Conduct
This project has adopted the [Amazon Open Source Code of Conduct](https://aws.github.io/code-of-conduct).
For more information see the [Code of Conduct FAQ](https://aws.github.io/code-of-conduct-faq) or contact
opensource-codeofconduct@amazon.com with any additional questions or comments.


## Security issue notifications
If you discover a potential security issue in this project we ask that you notify AWS/Amazon Security via our [vulnerability reporting page](http://aws.amazon.com/security/vulnerability-reporting/). Please do **not** create a public github issue.


## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. We will ask you to confirm the licensing of your contribution.

---

## Development Setup

```bash
git clone <repo-url> && cd agent-assisted-sdlc
npm install
cp sdlc-config.template.yaml sdlc-config.yaml
# Edit sdlc-config.yaml with your values
npx cdk synth --quiet  # Verify everything compiles
```

**Prerequisites:** Node.js 20+, AWS CDK CLI, AWS credentials configured.

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  GitHub Issue (agent:start label)                               │
│       │                                                         │
│       ▼                                                         │
│  Step Functions  ──►  Coding Assistant Runtime                  │
│                       (Claude Code / Codex / Kiro)              │
│                              │                                  │
│                              ▼                                  │
│                       AgentCore Gateway                         │
│                       ┌──────┼──────┐                          │
│                       ▼      ▼      ▼                          │
│                 Source    Project   Developer                   │
│                 Control   Mgmt     MCP Servers                 │
│                 MCP       MCP      (aws-docs, cfn-docs, ...)   │
└─────────────────────────────────────────────────────────────────┘
```

**CDK Stack Deployment Order:**
```
Infra → Gateway → SourceControl → ProjectManagement → DeveloperMcp → Assistant
```

Each stack can fail and be redeployed independently without affecting upstream stacks.

## Extension Points

### Adding a Coding Assistant

Create `coding-assistants/<name>/` with two subdirectories:

```
coding-assistants/<name>/
├── runtime/
│   ├── Dockerfile           # Container for AgentCore Runtime
│   └── main.py              # Health server (port 8080)
└── plugin/
    ├── <instruction-file>   # Pipeline instructions in your CLI's native format
    └── .mcp.json.template   # MCP gateway config (CDK renders {{GATEWAY_URL}}, {{REGION}})
```

**Runtime contract:**
- Health server on port 8080
- `GET /ping`, `GET /health` — health check endpoints
- `POST /invocations` — receives commands from Step Functions Lambda
- Mounts: `/mnt/workplace` (session storage), `/mnt/plugins` (shared plugins from Amazon S3 Files)

**Config entry:**
```yaml
codingAssistant:
  type: <name>    # Must match ASSISTANT_TO_DIR in lib/config.ts
```

**CDK mapping:** The `getAssistantDir()` function in `lib/config.ts` maps the type to the directory name. Add your type to the `ASSISTANT_TO_DIR` record.

---

### Adding a Source Control Platform

Create `source-control/<platform>/mcp/`:

```
source-control/<platform>/mcp/
├── main.py              # FastMCP server
├── Dockerfile
├── entrypoint.sh
├── pyproject.toml
└── README.md
```

**Required MCP tools:**

| Tool | Description |
|------|-------------|
| `create_branch` | Create a feature branch from the default branch |
| `push_files` | Stage files and push a commit |
| `create_pull_request` | Open a PR with title and body |
| `get_file_contents` | Read a file from a given ref |
| `list_commits` | List recent commits on a branch |
| `list_branches` | List available branches |
| `search_code` | Search repository code |

**Runtime contract:**
- FastMCP application using streamable-http transport on port 8000
- Authentication: generate short-lived tokens at container startup (stored in-memory, never exposed to gateway)
- Container max lifetime < token expiry (e.g., 55 min lifetime for 60 min tokens)

**Config entry:**
```yaml
sourceControl:
  type: <platform>
  <platform>:
    # Platform-specific credentials
```

---

### Adding a Project Management Platform

Create `project-management/<platform>/`:

```
project-management/<platform>/
├── mcp/
│   ├── main.py              # FastMCP server for issue operations
│   ├── Dockerfile
│   ├── entrypoint.sh
│   └── pyproject.toml
└── connector/
    ├── lambda/              # Lambda that starts Step Functions
    │   └── index.py
    ├── workflow/            # CI/CD trigger (GitHub Actions, webhook, etc.)
    └── README.md
```

**Required MCP tools:**

| Tool | Description |
|------|-------------|
| `issue_read` | Get issue details (title, body, comments) |
| `issue_write` | Update issue title or body |
| `add_issue_comment` | Post a comment on an issue |
| `set_labels` | Set status labels (stage:exploring, state:pr-created) |
| `list_issues` | List/filter issues |
| `search_issues` | Full-text search issues |

**Connector pattern:**
1. An external event (label added, webhook fired, manual trigger) invokes a Lambda
2. The Lambda resolves the full issue context (title, body, comments)
3. The Lambda calls `StartExecution` on the Step Functions state machine with the issue payload
4. The state machine orchestrates: setup session → invoke coding assistant

**Config entry:**
```yaml
projectManagement:
  type: <platform>
  <platform>:
    # Platform-specific settings
```

---

### Adding a Developer MCP Server

This is the simplest extension point. Create `gateway/developer-mcp-servers/<name>/`:

```
gateway/developer-mcp-servers/<name>/
├── main.py              # FastMCP server with your tools
├── Dockerfile
├── pyproject.toml
├── uv.lock
└── README.md
```

**Registration:** Add to `sdlc-config.yaml`:
```yaml
gateway:
  developerMcpServers:
    - name: my-server           # Alphanumeric + hyphens
      source: ./gateway/developer-mcp-servers/my-server
```

CDK automatically deploys the container and registers it as a gateway target on the next `cdk deploy`.

---

## CDK Architecture

**Key constructs** (in `lib/constructs/`):

| Construct | Purpose |
|-----------|---------|
| `network/vpc.ts` | Amazon VPC with BYO support |
| `gateway/mcp-gateway.ts` | Gateway + waiter + cleanup |
| `runtime/mcp-server.ts` | MCP server runtime (ECR + CodeBuild + CfnResource) |
| `runtime/coding-assistant.ts` | Coding assistant runtime with filesystem mounts |
| `storage/s3-files.ts` | Amazon S3 Files filesystem + mount targets + access point |
| `connectors/github/github-connector.ts` | GitHub App token Lambda + Secrets Manager |

## Testing

```bash
# Synthesize all stacks (validates TypeScript + cdk-nag)
npx cdk synth --quiet

# List stacks
npx cdk ls

# Deploy to a test account
npx cdk deploy --all

# Deploy a single stack
npx cdk deploy agentcore-sdlc-source-control
```

## Pull Request Guidelines

- One feature/fix per PR
- Branch naming: `feat/<description>` or `fix/<description>`
- Run `npx cdk synth --quiet` before pushing (ensures no cdk-nag violations)
- Include a test plan in the PR description
- If adding a new platform, include a working example in the PR
