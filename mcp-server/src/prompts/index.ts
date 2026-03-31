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

  _server.prompt(
    "init_project",
    "Interactive setup: detect project structure, connect OpenProject, write config files",
    { projectRoot: z.string().describe("Absolute path to project root") },
    async ({ projectRoot }) => {
      return {
        messages: [
          {
            role: "user" as const,
            content: {
              type: "text" as const,
              text: `Set up forgeplan for the project at ${projectRoot}. Follow these steps in order, asking the user for input at each step:

**Step 1: OpenProject Connection**
Ask the user for:
1. OpenProject URL (e.g. https://op.example.com)
2. OpenProject API key — tell them: "Log in → Avatar → My account → Access tokens → Generate → API"
3. Project slug (from the OpenProject URL)

Then call \`forgeplan_init_discover_statuses\` with their answers to verify the connection, fetch the user ID, and get available statuses.

Show the user: "Detected user: **{name}** (ID: {id})"

**Step 2: Layer Paths**
Ask: "Layer paths, comma-separated (e.g. \`src/backend,src/frontend\` or \`.\` for single-repo)"

Then call \`forgeplan_init_probe\` with the project root and layer paths.

Show the detected tech stacks, tools, hooks, and ask the user to confirm or adjust.

**Step 3: Optional Settings**
Ask for:
- PR reviewers (comma-separated usernames, or skip)
- Commit trailer (e.g. \`Co-Authored-By: bot <bot@noreply>\`, or skip)

**Step 4: Status Mapping**
Show the numbered status list from Step 1. Based on names, suggest mappings for:
- pickup_status — the "ready/todo" status
- in_progress_status — the "in progress" status
- success_status — the "in review" or "done" status
- partial_status — reuse in_progress or similar
- failure_status — 0 for no change, or a specific status

Ask the user to confirm or override each mapping.

**Step 5: Keyword Routing (optional)**
Ask: "Would you like to configure keyword-based routing? (For when WPs don't have a category set)"
If yes, for each layer ask for 3-5 keywords (e.g. "api, endpoint, controller" for backend).

**Step 6: Write Config**
Assemble forgeplan.config.json and forgeplan.local.json from all answers, then call \`forgeplan_init_write_config\` to write the files.

forgeplan.local.json should include:
- userId (from Step 1)
- toolPaths (from probe, null for on-PATH tools)
- hookConventions (from probe)
- layerOverrides with testCmd/lintFixCmd/formatCmd (from probe)

**Step 7: Summary**
Print:
\`\`\`
✓ forgeplan.config.json — shared project config
✓ forgeplan.local.json  — local toolchain + hooks
✓ .env                  — API key (gitignored)
✓ .gitignore            — updated

Next steps:
  Use forgeplan_doctor to verify setup
  Use process_work_package prompt to process a WP
\`\`\``,
            },
          },
        ],
      };
    },
  );
}
