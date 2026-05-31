import * as cdk from "aws-cdk-lib";
import * as iam from "aws-cdk-lib/aws-iam";
import * as cr from "aws-cdk-lib/custom-resources";
import { NagSuppressions } from "cdk-nag";
import { Construct } from "constructs";

import * as lambda from "aws-cdk-lib/aws-lambda";
import { SdlcConfig, ResourcePolicyStatement } from "../config";

export interface PoliciesStackProps extends cdk.StackProps {
  config: SdlcConfig;
  codingAssistantRuntimeArn: string;
  codingAssistantExecutionRoleArn: string;
  gatewayArn: string;
  gatewayRoleArn: string;
  mcpServerRuntimeArns: string[];
  mcpServerExecutionRoleArns: string[];
  setupLambdaRoleArn: string;
  pipelineLambdaRoleArn: string;
  tokenLambdaArn?: string;
}

function buildPolicy(
  resourceArn: string,
  defaultStatements: Record<string, unknown>[],
  customStatements?: ResourcePolicyStatement[],
): string {
  const statements = [...defaultStatements];
  if (customStatements) {
    for (const s of customStatements) {
      statements.push({
        Effect: "Allow",
        Principal: { AWS: Array.isArray(s.principal) ? s.principal : [s.principal] },
        Action: Array.isArray(s.action) ? s.action : [s.action],
        Resource: resourceArn,
      });
    }
  }
  return JSON.stringify({ Version: "2012-10-17", Statement: statements });
}

export class PoliciesStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: PoliciesStackProps) {
    super(scope, id, props);

    const { config } = props;
    const customPolicies = config.resourcePolicies;

    const policyActions = new iam.PolicyStatement({
      actions: [
        "bedrock-agentcore:PutResourcePolicy",
        "bedrock-agentcore:DeleteResourcePolicy",
        "bedrock-agentcore:GetResourcePolicy",
      ],
      resources: ["*"],
    });

    // 1. Coding Assistant Runtime — only invokable by Lambda roles
    const assistantPolicy = buildPolicy(
      props.codingAssistantRuntimeArn,
      [{
        Sid: "AllowLambdaInvoke",
        Effect: "Allow",
        Principal: { AWS: [props.setupLambdaRoleArn, props.pipelineLambdaRoleArn] },
        Action: "bedrock-agentcore:InvokeAgentRuntime",
        Resource: props.codingAssistantRuntimeArn,
      }],
      customPolicies?.codingAssistant,
    );

    new cr.AwsCustomResource(this, "CodingAssistantPolicy", {
      installLatestAwsSdk: true,
      onCreate: {
        service: "bedrock-agentcore-control",
        action: "putResourcePolicy",
        parameters: { resourceArn: props.codingAssistantRuntimeArn, policy: assistantPolicy },
        physicalResourceId: cr.PhysicalResourceId.of("policy-coding-assistant"),
      },
      onUpdate: {
        service: "bedrock-agentcore-control",
        action: "putResourcePolicy",
        parameters: { resourceArn: props.codingAssistantRuntimeArn, policy: assistantPolicy },
        physicalResourceId: cr.PhysicalResourceId.of("policy-coding-assistant"),
      },
      onDelete: {
        service: "bedrock-agentcore-control",
        action: "deleteResourcePolicy",
        parameters: { resourceArn: props.codingAssistantRuntimeArn },
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([policyActions]),
    });

    // 2. Gateway — only invokable by coding assistant execution role
    const gatewayPolicy = buildPolicy(
      props.gatewayArn,
      [{
        Sid: "AllowAssistantInvoke",
        Effect: "Allow",
        Principal: { AWS: [props.codingAssistantExecutionRoleArn] },
        Action: "bedrock-agentcore:InvokeGateway",
        Resource: props.gatewayArn,
      }],
      customPolicies?.gateway,
    );

    new cr.AwsCustomResource(this, "GatewayPolicy", {
      installLatestAwsSdk: true,
      onCreate: {
        service: "bedrock-agentcore-control",
        action: "putResourcePolicy",
        parameters: { resourceArn: props.gatewayArn, policy: gatewayPolicy },
        physicalResourceId: cr.PhysicalResourceId.of("policy-gateway"),
      },
      onUpdate: {
        service: "bedrock-agentcore-control",
        action: "putResourcePolicy",
        parameters: { resourceArn: props.gatewayArn, policy: gatewayPolicy },
        physicalResourceId: cr.PhysicalResourceId.of("policy-gateway"),
      },
      onDelete: {
        service: "bedrock-agentcore-control",
        action: "deleteResourcePolicy",
        parameters: { resourceArn: props.gatewayArn },
      },
      policy: cr.AwsCustomResourcePolicy.fromStatements([policyActions]),
    });

    // 3. MCP Server Runtimes — only invokable by gateway role
    for (const [i, runtimeArn] of props.mcpServerRuntimeArns.entries()) {
      const mcpPolicy = buildPolicy(
        runtimeArn,
        [{
          Sid: "AllowGatewayInvoke",
          Effect: "Allow",
          Principal: { AWS: [props.gatewayRoleArn] },
          Action: "bedrock-agentcore:InvokeAgentRuntime",
          Resource: runtimeArn,
        }],
        customPolicies?.mcpServers,
      );

      new cr.AwsCustomResource(this, `McpServerPolicy${i}`, {
        installLatestAwsSdk: true,
        onCreate: {
          service: "bedrock-agentcore-control",
          action: "putResourcePolicy",
          parameters: { resourceArn: runtimeArn, policy: mcpPolicy },
          physicalResourceId: cr.PhysicalResourceId.of(`policy-mcp-${i}`),
        },
        onUpdate: {
          service: "bedrock-agentcore-control",
          action: "putResourcePolicy",
          parameters: { resourceArn: runtimeArn, policy: mcpPolicy },
          physicalResourceId: cr.PhysicalResourceId.of(`policy-mcp-${i}`),
        },
        onDelete: {
          service: "bedrock-agentcore-control",
          action: "deleteResourcePolicy",
          parameters: { resourceArn: runtimeArn },
        },
        policy: cr.AwsCustomResourcePolicy.fromStatements([policyActions]),
      });
    }

    // 4. Token Lambda — only invokable by MCP server roles + Setup Lambda
    if (props.tokenLambdaArn) {
      const tokenFn = lambda.Function.fromFunctionAttributes(this, "TokenFunction", {
        functionArn: props.tokenLambdaArn,
        sameEnvironment: true,
      });
      const allowedPrincipals = [
        ...props.mcpServerExecutionRoleArns,
        props.setupLambdaRoleArn,
      ];
      for (const [i, principalArn] of allowedPrincipals.entries()) {
        tokenFn.addPermission(`AllowInvoke${i}`, {
          principal: new iam.ArnPrincipal(principalArn),
          action: "lambda:InvokeFunction",
        });
      }
    }

    NagSuppressions.addStackSuppressions(this, [
      { id: "AwsSolutions-IAM5", reason: "Resource policy management requires wildcard for agentcore resources" },
      { id: "AwsSolutions-IAM4", reason: "Custom resource Lambda uses AWS managed execution role policy" },
      { id: "AwsSolutions-L1", reason: "Custom resource Lambda runtime is managed by CDK" },
    ], true);
  }
}
