import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";

export function registerPrompts(
  _server: McpServer,
  _state: ServerState,
): void {
  _server.prompt(
    "process_work_package",
    "Full pipeline to process a work package: load config, fetch, route, generate, commit, PR, finish",
    { wpId: z.string().describe("OpenProject work package ID") },
    async ({ wpId }) => {
      return {
        messages: [
          {
            role: "user" as const,
            content: {
              type: "text" as const,
              text: `Process OpenProject work package #${wpId} using the forgeplan pipeline.

Follow these steps in order:

1. **Load config**: Call \`forgeplan_load_config\` with the project root directory.

2. **Fetch WP**: Call \`forgeplan_fetch_wp\` with wpId=${wpId} to get WP data and quality gate evaluation.

3. **Fetch context**: Call \`forgeplan_fetch_wp_context\` with wpId=${wpId} to get parent chain, siblings, children, relations, and comments.

4. **Review quality gate**: If the quality gate has warnings, present them to the user and wait for answers before proceeding. If there are hard blocks, stop and explain.

5. **Route to layers**: Call \`forgeplan_route_wp\` with the WP metadata. If needsConfirmation is true, ask the user to confirm.

6. **Read generation rules**: Read the resource \`forgeplan://rules/{type}\` where type matches the WP type (bug, feature, epic, story, subtask, task).

7. **Claim WP**: Call \`forgeplan_claim_wp\` to set assignee and status to in_progress.

8. **Derive branch**: Call \`forgeplan_derive_branch\` to get the branch name per layer.

9. **Per-layer loop**: For each target layer:
   a. Call \`forgeplan_git_prepare_branch\` to create or resume the branch
   b. **Generate code**: Write the implementation following the generation rules and WP requirements
   c. Call \`forgeplan_run_layer_checks\` to format, lint, test, and build
   d. Call \`forgeplan_git_commit_and_push\` to stage, commit, and push
   e. Call \`forgeplan_git_create_pr\` to create a pull request

10. **Cross-link PRs**: If multiple layers, call \`forgeplan_git_crosslink_prs\`.

11. **Finish**: Call \`forgeplan_finish_wp\` to update OP status, post summary comment, and log the run.`,
            },
          },
        ],
      };
    },
  );

  _server.prompt(
    "review_generation",
    "Review generated code against WP requirements and generation rules before committing",
    {
      wpId: z.string().describe("Work package ID"),
      layerName: z.string().describe("Layer name to review"),
    },
    async ({ wpId, layerName }) => {
      return {
        messages: [
          {
            role: "user" as const,
            content: {
              type: "text" as const,
              text: `Review the generated code for WP #${wpId} in the "${layerName}" layer before committing.

Check the following:
1. **Correctness**: Does the code implement all requirements from the WP description?
2. **Generation rules**: Does the code follow the type-specific generation rules from \`forgeplan://rules/{type}\`?
3. **Conventions**: Does the code follow the project's CLAUDE.md conventions?
4. **Tests**: If testParityRequired is true, are corresponding test files present?
5. **Imports**: Are all imports valid and pointing to existing modules?
6. **Security**: No hardcoded secrets, proper input validation at boundaries
7. **Completeness**: No TODOs, no placeholder implementations, no commented-out code

Call \`forgeplan_git_status\` for "${layerName}" to see what files were changed.

If issues are found, fix them before proceeding to commit.`,
            },
          },
        ],
      };
    },
  );
}
