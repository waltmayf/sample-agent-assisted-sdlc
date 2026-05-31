#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { createStacks } from "../lib/sdlc-stack";
import { loadConfig } from "../lib/config";

const app = new cdk.App();

const configPath = app.node.tryGetContext("config") || "./sdlc-config.yaml";
const config = loadConfig(configPath);

createStacks(app, config);

app.synth();
