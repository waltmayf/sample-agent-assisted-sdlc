import * as cdk from "aws-cdk-lib";
import * as ec2 from "aws-cdk-lib/aws-ec2";
import { Construct } from "constructs";

import { SdlcVpc } from "../constructs/network/vpc";
import { SdlcConfig } from "../config";

export interface InfrastructureStackProps extends cdk.StackProps {
  config: SdlcConfig;
}

export class InfrastructureStack extends cdk.Stack {
  public readonly vpc: ec2.IVpc;
  public readonly agentRuntimeSecurityGroup: ec2.ISecurityGroup;
  public readonly fileSystemSecurityGroup: ec2.ISecurityGroup;

  constructor(scope: Construct, id: string, props: InfrastructureStackProps) {
    super(scope, id, props);

    const { config } = props;

    const network = new SdlcVpc(this, "Network", {
      maxAzs: config.vpc?.maxAzs,
      natGateways: config.vpc?.natGateways,
      vpcId: config.vpc?.vpcId,
      privateSubnetIds: config.vpc?.privateSubnetIds,
      agentRuntimeSecurityGroupId: config.vpc?.agentRuntimeSecurityGroupId,
      fileSystemSecurityGroupId: config.vpc?.fileSystemSecurityGroupId,
    });

    this.vpc = network.vpc;
    this.agentRuntimeSecurityGroup = network.agentRuntimeSecurityGroup;
    this.fileSystemSecurityGroup = network.fileSystemSecurityGroup;
  }
}
