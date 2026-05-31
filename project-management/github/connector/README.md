# GitHub Connector Setup

This connector triggers the SDLC pipeline from GitHub Issues and authenticates with the GitHub API via a GitHub App.

## Step 1: Create a GitHub App

1. Go to **GitHub > Settings > Developer settings > GitHub Apps > New GitHub App**

2. Configure:

   | Field | Value |
   |-------|-------|
   | App name | `agentcore-sdlc` (or your choice) |
   | Homepage URL | `https://github.com/your-org` |
   | Callback URL | Leave blank (not needed) |
   | Webhook | Uncheck "Active" |

3. Set **Repository Permissions**:

   | Permission | Access | Used by |
   |-----------|--------|---------|
   | Contents | Read & Write | `git clone`, `push_files`, `create_branch` |
   | Pull requests | Read & Write | `create_pull_request`, `update_pull_request` |
   | Issues | Read & Write | `issue_read`, `add_issue_comment`, set labels |
   | Metadata | Read-only | Required by GitHub |

4. Click **Create GitHub App**

5. Note the **Client ID** (starts with `Iv...`)

6. Generate a **Private Key** (Settings > Private keys > Generate). Download the `.pem` file and place it in the project root.

## Step 2: Install the GitHub App

1. Go to your GitHub App's page > **Install App**
2. Select your **personal account or organization**
3. Choose **"Only select repositories"** and pick the repos the agent should access
4. Note the **Installation ID**: find it at `https://github.com/settings/installations` (click the app, the ID is in the URL: `/installations/<ID>`)

> **Private Repositories**: The GitHub App automatically has access to private repos you select during installation. No additional config needed.

> **Branch Protection**: To prevent the agent from pushing directly to `main`, add a branch protection rule:
> 1. Repository > Settings > Branches > Add rule
> 2. Branch name pattern: `main`
> 3. Enable: Require a pull request, Require approvals (at least 1), Do not allow bypassing

## Step 3: Add values to config

Edit `sdlc-config.yaml`:

```yaml
sourceControl:
  type: github
  github:
    appClientId: "Iv23li..."           # Client ID from Step 1
    installationId: "134697255"        # Installation ID from Step 2
    privateKeyPath: "./my-app.pem"     # Path to .pem file from Step 1
```

## Step 4: Deploy

```bash
npx cdk deploy
```

The CDK stack will:
- Store the private key in AWS Secrets Manager
- Deploy the GitHub MCP servers (source control + project management)
- Register them as gateway targets
- Create the Step Functions pipeline
- Create a GitHub Actions OIDC role

## Step 5: Connect your target repository

After deploy, add the following secrets to your target repo (Settings > Secrets and variables > Actions):

| Secret | Value (from CDK output) |
|--------|------------------------|
| `SDLC_PIPELINE_ROLE_ARN` | `GitHubActionsRoleArn` output |
| `SDLC_PIPELINE_STATE_MACHINE_ARN` | `StateMachineArn` output |

Then copy the workflow:

```bash
cp project-management/github/connector/workflow/agent-start.yml \
   /path/to/your-repo/.github/workflows/agent-start.yml
```

