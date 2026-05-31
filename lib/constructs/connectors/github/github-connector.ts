import * as cdk from "aws-cdk-lib";
import * as lambda from "aws-cdk-lib/aws-lambda";
import * as secretsmanager from "aws-cdk-lib/aws-secretsmanager";
import * as iam from "aws-cdk-lib/aws-iam";
import * as path from "path";
import * as fs from "fs";
import { Construct } from "constructs";
import { NagSuppressions } from "cdk-nag";

export interface GitHubConnectorProps {
  appClientId: string;
  installationId: string;
  privateKeyPath: string;
  toolsets?: string;
  maxLifetime?: number;
}

export class GitHubConnector extends Construct {
  public readonly privateKeySecret: secretsmanager.ISecret;
  public readonly tokenFunction: lambda.IFunction;

  constructor(scope: Construct, id: string, props: GitHubConnectorProps) {
    super(scope, id);

    const { appClientId, installationId, privateKeyPath } = props;

    if (!appClientId || !installationId || !privateKeyPath) {
      throw new Error(
        "GitHubConnector requires appClientId, installationId, and privateKeyPath. " +
        "Set via env vars (GITHUB_APP_CLIENT_ID, GITHUB_INSTALLATION_ID, GITHUB_PRIVATE_KEY_PATH).",
      );
    }
    if (!fs.existsSync(privateKeyPath)) {
      throw new Error(`privateKeyPath not found: ${privateKeyPath}`);
    }

    const pemContents = fs.readFileSync(privateKeyPath, "utf-8");

    this.privateKeySecret = new secretsmanager.Secret(this, "PrivateKey", {
      description: "GitHub App private key (.pem)",
      secretStringValue: cdk.SecretValue.unsafePlainText(pemContents),
    });

    this.tokenFunction = new lambda.Function(this, "TokenFunction", {
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: "index.handler",
      timeout: cdk.Duration.seconds(10),
      memorySize: 128,
      environment: {
        GITHUB_APP_CLIENT_ID: appClientId,
        GITHUB_INSTALLATION_ID: installationId,
        PRIVATE_KEY_SECRET_ARN: this.privateKeySecret.secretArn,
      },
      code: lambda.Code.fromAsset(path.join(__dirname, "../../../../project-management/github/connector/token-lambda"), {
        bundling: {
          image: lambda.Runtime.PYTHON_3_12.bundlingImage,
          command: ["bash", "-c", "pip install -r requirements.txt -t /asset-output && cp index.py /asset-output/"],
          local: {
            tryBundle(outputDir: string) {
              const { execSync } = require("child_process");
              const lambdaDir = path.join(__dirname, "../../../../project-management/github/connector/token-lambda");
              execSync(
                `pip install -r ${lambdaDir}/requirements.txt -t ${outputDir} --platform manylinux2014_x86_64 --python-version 3.12 --only-binary=:all: && cp ${lambdaDir}/index.py ${outputDir}/`,
                { stdio: "inherit" },
              );
              return true;
            },
          },
        },
      }),
    });

    this.privateKeySecret.grantRead(this.tokenFunction);

    NagSuppressions.addResourceSuppressions(this.privateKeySecret, [
      { id: "AwsSolutions-SMG4", reason: "GitHub App private keys are manually rotated, not auto-rotatable" },
    ], true);

    NagSuppressions.addResourceSuppressions(this.tokenFunction, [
      { id: "AwsSolutions-L1", reason: "Python 3.12 is the target runtime for PyJWT compatibility" },
    ], true);

    new cdk.CfnOutput(scope, "GitHubTokenFunctionArn", { value: this.tokenFunction.functionArn });
    new cdk.CfnOutput(scope, "GitHubPrivateKeySecretArn", { value: this.privateKeySecret.secretArn });
  }

  public grantTokenGeneration(role: iam.IRole): void {
    this.privateKeySecret.grantRead(role);
  }
}
