# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""Assistant strategy registry."""

from assistants.claude import ClaudeStrategy
from assistants.codex import CodexStrategy
from assistants.kiro import KiroStrategy

STRATEGIES = {
    "claude-code": ClaudeStrategy,
    "codex": CodexStrategy,
    "kiro": KiroStrategy,
}
