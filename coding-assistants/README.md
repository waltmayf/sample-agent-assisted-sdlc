# Coding Assistants

> [!IMPORTANT]
> This sample is in preview and under active development.

AI agents that read issues, explore codebases, implement features, and open pull requests. Each assistant runs as a container in [AgentCore Runtime](https://docs.aws.amazon.com/bedrock-agentcore/latest/devguide/agents-tools-runtime.html) with access to tools via the MCP gateway.

## Implementations

| Assistant | Directory | CLI | Status |
|-----------|-----------|-----|--------|
| Claude Code | [`claude-code/`](./claude-code/) | `claude` | Stable |
| Kiro | [`kiro/`](./kiro/) | `kiro-cli` | Experimental |
| Codex | [`codex/`](./codex/) | `codex` | Experimental |

> [!NOTE]
> **Kiro and Codex are experimental.** They implement the same issue-to-PR pipeline as Claude Code but without the multi-agent orchestration (skills system) or security hooks. Claude Code remains the recommended choice for production use. Kiro requires a `KIRO_API_KEY` (Pro+ subscription). Codex requires an `OPENAI_API_KEY`.

## How It Works

Each coding assistant has two parts:

```
coding-assistants/<name>/
├── runtime/          # Container image (CLI + health server)
└── plugin/           # Instructions + MCP config deployed to S3 Files (/mnt/plugins)
```

**Runtime** — a minimal health server container. The coding CLI is invoked via `execute_command` from Step Functions (shell commands inside the container).

**Plugin** — defines how the assistant orchestrates work. Deployed to S3 Files and mounted at `/mnt/plugins/<name>`. Contents vary by assistant:

| Assistant | Plugin contents |
|-----------|----------------|
| Claude Code | Skills (multi-agent pipeline), hooks (security gates), settings (model, permissions), MCP config |
| Kiro | Steering file (`steering/agent.md`), MCP config |
| Codex | Instruction file (`AGENTS.md`), MCP config |

### Execution Flow

```
Step Functions → Setup Lambda → execute_command("git clone ...")
                              → execute_command("cp plugins to workspace")
             → Pipeline Lambda → execute_command("<cli> <prompt>")
                                       │
                                       ▼
                              CLI loads instructions from workspace
                              Pipeline: explore → implement → push → PR
                              MCP tools (via gateway) handle GitHub operations
```

## Assistant-Specific Details

### Claude Code

Full multi-agent orchestration with complexity routing:

- **Simple issues** (Path A): Orchestrator handles inline — explore, implement, push, PR
- **Complex issues** (Path B): Delegates to subagents via Agent tool — explore → clarification → implement → critique → PR

Security hooks (`hooks/`) gate every tool call: scope-guard restricts to assigned repo/issue, secret-guard blocks credential leaks, bash-guard blocks destructive commands.

CLI invocation:
```bash
claude --continue --dangerously-skip-permissions --plugin-dir /mnt/workplace/gitproject \
  -p "Follow the orchestrator skill for issue #N..." \
  --allowedTools "mcp__gateway__*,Read,Write,Edit,Bash,Task,ToolSearch"
```

### Kiro

Single-pass pipeline using native steering file (`.kiro/steering/agent.md`):

CLI invocation:
```bash
kiro-cli chat --no-interactive --trust-all-tools --require-mcp-startup \
  "Follow the orchestrator instructions in .kiro/steering/agent.md for issue #N..."
```

Auth: `KIRO_API_KEY` environment variable.

### Codex

Single-pass pipeline using native instruction file (`AGENTS.md` at workspace root):

CLI invocation:
```bash
codex -q --approval-mode full-auto \
  "Follow the orchestrator instructions in AGENTS.md for issue #N..."
```

Auth: `OPENAI_API_KEY` environment variable.

## Adding a New Coding Assistant

### Step 1: Create directory structure

```
coding-assistants/<name>/
├── runtime/
│   ├── Dockerfile           # Install your CLI tool + health server
│   └── main.py              # FastAPI health server (port 8080)
└── plugin/
    ├── <instruction-file>   # Pipeline instructions in your CLI's native format
    └── .mcp.json.template   # MCP gateway config (CDK renders {{GATEWAY_URL}}, {{REGION}})
```

### Step 2: Implement the runtime

The runtime is a simple health server. Only the Dockerfile differs between assistants (installing the specific CLI). See `kiro/runtime/Dockerfile` or `codex/runtime/Dockerfile` for minimal examples.

### Step 3: Create the plugin

At minimum you need an instruction file and MCP config template. The instruction file should tell the agent to:
1. Read `.dev-claude/issue.json` for the issue specification
2. Read `.dev-claude/project.json` for repo metadata (owner, repo, issue_number)
3. Implement the feature
4. Push via `mcp__gateway__github-code___push_files` (no git credentials in container)
5. Open PR via `mcp__gateway__github-code___create_pull_request`
6. Set labels via `mcp__gateway__github-issues___issue_write`

### Step 4: Write the invocation strategy

Create `project-management/shared/assistants/<name>.py` implementing `AssistantStrategy.run_pipeline()`. See `kiro.py` or `codex.py` for simple examples, `claude.py` for the full-featured version.

Register in `project-management/shared/assistants/__init__.py`.

### Step 5: Register in CDK config

Add to `ASSISTANT_TO_DIR` in [`lib/config.ts`](../lib/config.ts):

```typescript
const ASSISTANT_TO_DIR: Record<string, string> = {
  "claude-code": "claude-code",
  codex: "codex",
  kiro: "kiro",
};
```

### Step 6: Configure and deploy

```yaml
codingAssistant:
  type: kiro    # or codex, claude-code
  model: your-model-id
```

```bash
npx cdk deploy <project>-assistant
```

## Security Model

> [!WARNING]
> Autonomous agents run without human supervision. Read **[SECURITY-PRACTICES.md](../SECURITY-PRACTICES.md)** for the full security hook reference, threat model, and guidance on applying guardrails to new assistants.

| Concern | How it's handled |
|---------|-----------------|
| Credential isolation | Assistant never sees GitHub tokens. MCP gateway handles auth internally. |
| Permission scoping | CLI flags control tool access (`--allowedTools`, `--trust-tools`, `--approval-mode`) |
| Tool-call interception | Claude Code: PreToolUse hooks block out-of-scope operations, secrets, destructive commands |
| Session isolation | Each issue gets its own AgentCore session with dedicated filesystem |
| Token lifetime | Runtime max lifetime (40 min) < GitHub token expiry (60 min) |

Claude Code ships with 4 security hooks (label governance, scope guard, secret guard, bash guard) that intercept every tool call. Kiro and Codex do not yet implement equivalent hooks — see [SECURITY-PRACTICES.md](../SECURITY-PRACTICES.md) for mitigation options.
