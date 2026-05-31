import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import { Construct } from "constructs";
import { NagSuppressions } from "cdk-nag";

export interface SdlcVpcProps {
  // Create new VPC
  maxAzs?: number;
  natGateways?: number;
  // Bring your own VPC
  vpcId?: string;
  privateSubnetIds?: string[];
  agentRuntimeSecurityGroupId?: string;
  fileSystemSecurityGroupId?: string;
}

export class SdlcVpc extends Construct {
  public readonly vpc: ec2.IVpc;
  public readonly agentRuntimeSecurityGroup: ec2.ISecurityGroup;
  public readonly fileSystemSecurityGroup: ec2.ISecurityGroup;

  constructor(scope: Construct, id: string, props?: SdlcVpcProps) {
    super(scope, id);

    if (props?.vpcId) {
      this.initFromExisting(props);
    } else {
      this.initNew(props);
    }
  }

  private initFromExisting(props: SdlcVpcProps): void {
    if (!props.privateSubnetIds?.length) {
      throw new Error("vpc.privateSubnetIds is required when using an existing VPC");
    }
    if (!props.agentRuntimeSecurityGroupId) {
      throw new Error("vpc.agentRuntimeSecurityGroupId is required when using an existing VPC");
    }
    if (!props.fileSystemSecurityGroupId) {
      throw new Error("vpc.fileSystemSecurityGroupId is required when using an existing VPC");
    }

    (this as any).vpc = ec2.Vpc.fromLookup(this, "Vpc", { vpcId: props.vpcId });

    (this as any).agentRuntimeSecurityGroup = ec2.SecurityGroup.fromSecurityGroupId(
      this, "AgentRuntimeSG", props.agentRuntimeSecurityGroupId,
    );

    (this as any).fileSystemSecurityGroup = ec2.SecurityGroup.fromSecurityGroupId(
      this, "FileSystemSG", props.fileSystemSecurityGroupId,
    );
  }

  private initNew(props?: SdlcVpcProps): void {
    const vpc = new ec2.Vpc(this, "Vpc", {
      maxAzs: props?.maxAzs ?? 2,
      natGateways: props?.natGateways ?? 1,
      subnetConfiguration: [
        { name: "Public", subnetType: ec2.SubnetType.PUBLIC, cidrMask: 24 },
        { name: "Private", subnetType: ec2.SubnetType.PRIVATE_WITH_EGRESS, cidrMask: 24 },
      ],
    });
    (this as any).vpc = vpc;

    const fileSystemSg = new ec2.SecurityGroup(this, "FileSystemSG", {
      vpc,
      description: "Security group for S3 Files / EFS mount targets",
      allowAllOutbound: false,
    });
    (this as any).fileSystemSecurityGroup = fileSystemSg;

    const agentRuntimeSg = new ec2.SecurityGroup(this, "AgentRuntimeSG", {
      vpc,
      description: "Security group for AgentCore runtime workloads",
      allowAllOutbound: true,
    });
    (this as any).agentRuntimeSecurityGroup = agentRuntimeSg;

    fileSystemSg.addIngressRule(
      agentRuntimeSg,
      ec2.Port.tcp(2049),
      "Allow NFS from AgentCore runtime",
    );

    // VPC endpoints for AgentCore
    vpc.addGatewayEndpoint("S3Endpoint", {
      service: ec2.GatewayVpcEndpointAwsService.S3,
    });

    const interfaceEndpoints: [string, ec2.InterfaceVpcEndpointAwsService][] = [
      ["EcrApi", ec2.InterfaceVpcEndpointAwsService.ECR],
      ["EcrDocker", ec2.InterfaceVpcEndpointAwsService.ECR_DOCKER],
      ["CloudWatchLogs", ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_LOGS],
      ["CloudWatchMonitoring", ec2.InterfaceVpcEndpointAwsService.CLOUDWATCH_MONITORING],
      ["XRay", ec2.InterfaceVpcEndpointAwsService.XRAY],
      ["Bedrock", ec2.InterfaceVpcEndpointAwsService.BEDROCK],
      ["BedrockRuntime", ec2.InterfaceVpcEndpointAwsService.BEDROCK_RUNTIME],
      ["Sts", ec2.InterfaceVpcEndpointAwsService.STS],
    ];

    for (const [endpointId, service] of interfaceEndpoints) {
      vpc.addInterfaceEndpoint(endpointId, {
        service,
        privateDnsEnabled: true,
        securityGroups: [agentRuntimeSg],
      });
    }

    NagSuppressions.addResourceSuppressions(vpc, [
      { id: "AwsSolutions-VPC7", reason: "VPC Flow Logs omitted for cost — enable in production" },
    ], true);

    NagSuppressions.addResourceSuppressions(agentRuntimeSg, [
      { id: "AwsSolutions-EC23", reason: "Agent runtime needs outbound internet for GitHub/PyPI access" },
    ]);
  }
}
