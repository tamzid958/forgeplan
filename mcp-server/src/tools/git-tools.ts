import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { deriveBranchName } from "../git/branch-namer.js";
import {
  gitStatus,
  gitFetch,
  gitPrepareBranch,
  gitStageAll,
  gitCommit,
  gitPush,
  gitDiffNames,
  gitDeleteBranch,
} from "../git/operations.js";
import { createPR, closePR, getPRBody, editPRBody } from "../git/pr.js";
import { findRunByWpId } from "../util/logger.js";

function requireConfig(state: ServerState) {
  if (!state.config || !state.projectRoot) {
    throw new Error("Config not loaded. Call forgeplan_load_config first.");
  }
  return { config: state.config, projectRoot: state.projectRoot };
}

function getLayerCwd(
  state: ServerState,
  layerName: string,
): string {
  const { config, projectRoot } = requireConfig(state);
  const layer = config.layers[layerName];
  if (!layer) throw new Error(`Unknown layer: ${layerName}`);
  return layer.repoRoot ?? projectRoot;
}

export function registerGitTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_derive_branch",
    "Derive branch name from work package metadata",
    {
      wpId: z.number().describe("Work package ID"),
      wpType: z.string().describe("Work package type"),
      subject: z.string().describe("Work package subject"),
    },
    async ({ wpId, wpType, subject }) => {
      try {
        const { config } = requireConfig(state);
        const perLayer: Record<
          string,
          { branchName: string; branchType: string; baseBranch: string }
        > = {};

        for (const [name] of Object.entries(config.layers)) {
          const baseBranch =
            config.gitInfo[name]?.baseBranch ?? "main";
          const info = deriveBranchName(
            wpId,
            wpType,
            subject,
            config.hookConventions,
            baseBranch,
          );
          perLayer[name] = info;
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(perLayer, null, 2),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_git_prepare_branch",
    "Fetch and prepare git branch for a layer (create or resume)",
    {
      layerName: z.string().describe("Layer name from config"),
      branchName: z.string().describe("Target branch name"),
    },
    async ({ layerName, branchName }) => {
      try {
        const { config, projectRoot } = requireConfig(state);
        const cwd = getLayerCwd(state, layerName);
        const baseBranch =
          config.gitInfo[layerName]?.baseBranch ?? "main";

        // Check run log for skip
        const prevRun = await findRunByWpId(projectRoot, 0);
        if (prevRun) {
          const layerResult = prevRun.layers.find(
            (l) => l.name === layerName,
          );
          if (layerResult?.result === "SUCCESS") {
            return {
              content: [
                {
                  type: "text" as const,
                  text: JSON.stringify({
                    status: "skipped",
                    reason: "Previous run was SUCCESS",
                  }),
                },
              ],
            };
          }
        }

        await gitFetch(cwd);
        const result = await gitPrepareBranch(cwd, branchName, baseBranch);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                layerName,
                branchName,
                baseBranch,
                ...result,
              }),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_git_status",
    "Get git status for a layer",
    {
      layerName: z.string().describe("Layer name from config"),
    },
    async ({ layerName }) => {
      try {
        const cwd = getLayerCwd(state, layerName);
        const { config } = requireConfig(state);
        const baseBranch =
          config.gitInfo[layerName]?.baseBranch ?? "main";

        const status = await gitStatus(cwd);
        const diffFiles = status.clean
          ? []
          : await gitDiffNames(cwd, baseBranch);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                { layerName, ...status, diffFiles },
                null,
                2,
              ),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_git_commit_and_push",
    "Stage, commit, and push changes for a layer",
    {
      layerName: z.string().describe("Layer name"),
      wpId: z.number().describe("Work package ID"),
      wpType: z.string().describe("Work package type"),
      subject: z.string().describe("Work package subject"),
      result: z.enum(["SUCCESS", "PARTIAL"]).describe("Generation result"),
      branchName: z.string().describe("Branch name"),
      assumptions: z
        .array(z.string())
        .optional()
        .describe("Assumptions made during generation"),
    },
    async ({ layerName, wpId, wpType, subject, result, branchName, assumptions }) => {
      try {
        const { config } = requireConfig(state);
        const cwd = getLayerCwd(state, layerName);

        // Build conventional commit message
        const typeMap: Record<string, string> = {
          feature: "feat",
          "user story": "feat",
          epic: "feat",
          bug: "fix",
          task: "chore",
          subtask: "chore",
        };
        const prefix = typeMap[wpType.toLowerCase()] ?? "chore";
        const maxLen = config.hookConventions.commitSubjectMaxLength ?? 72;

        let commitSubject = `${prefix}(WP-${wpId}): ${subject}`;
        if (commitSubject.length > maxLen) {
          commitSubject =
            commitSubject.substring(0, maxLen - 3) + "...";
        }
        if (result === "PARTIAL") {
          commitSubject = `[WIP] ${commitSubject}`;
        }

        const opUrl = config.openproject.url.replace(/\/+$/, "");
        let commitBody = `\nGenerated by forgeplan\nResult: ${result}\nOpenProject: ${opUrl}/work_packages/${wpId}`;
        if (config.commitTrailer) {
          commitBody += `\n${config.commitTrailer}`;
        }
        if (assumptions?.length) {
          commitBody += "\n\nAssumptions:";
          for (const a of assumptions) {
            commitBody += `\n[ASSUMPTION]: ${a}`;
          }
        }

        const fullMessage = commitSubject + commitBody;

        await gitStageAll(cwd);
        const commitResult = await gitCommit(cwd, fullMessage);
        const pushResult = await gitPush(cwd, branchName);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                layerName,
                sha: commitResult.sha,
                push: pushResult,
                commitSubject,
              }),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_git_create_pr",
    "Create a pull request for a layer",
    {
      layerName: z.string().describe("Layer name"),
      wpId: z.number().describe("Work package ID"),
      subject: z.string().describe("Work package subject"),
      result: z.enum(["SUCCESS", "PARTIAL"]).describe("Generation result"),
      branchName: z.string().describe("Branch name"),
      baseBranch: z.string().describe("Base branch to merge into"),
      assumptions: z
        .array(z.string())
        .optional()
        .describe("Assumptions from quality gate"),
    },
    async ({ layerName, wpId, subject, result, branchName, baseBranch, assumptions }) => {
      try {
        const { config } = requireConfig(state);
        const cwd = getLayerCwd(state, layerName);
        const gitInfo = config.gitInfo[layerName];
        if (!gitInfo) throw new Error(`No git info for layer: ${layerName}`);

        const opUrl = config.openproject.url.replace(/\/+$/, "");
        const changedFiles = await gitDiffNames(cwd, baseBranch);

        let body = `## Auto-generated by forgeplan\n\n`;
        body += `**OpenProject WP:** #${wpId} — [View](${opUrl}/work_packages/${wpId})\n`;
        body += `**Result:** ${result}\n\n`;
        body += `### Files Changed\n`;
        body += changedFiles.map((f) => `- ${f}`).join("\n");

        if (assumptions?.length) {
          body += `\n\n### Assumptions\n`;
          body += assumptions.map((a) => `- [ASSUMPTION]: ${a}`).join("\n");
        }

        body += `\n\n---\nGenerated by forgeplan (MCP server)`;

        const typeMap: Record<string, string> = {
          feature: "feat",
          "user story": "feat",
          epic: "feat",
          bug: "fix",
          task: "chore",
          subtask: "chore",
        };
        const prefix = typeMap[subject.toLowerCase()] ?? "chore";
        const title = `${prefix}(WP-${wpId}): ${subject}`;

        const labels = ["auto-generated", `wp-${wpId}`];

        const pr = await createPR(cwd, gitInfo, {
          title,
          body,
          baseBranch,
          reviewers: config.reviewers,
          labels,
        });

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                layerName,
                prUrl: pr.url,
                prNumber: pr.number,
              }),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_git_crosslink_prs",
    "Edit PR bodies to add Related PRs section for multi-layer work",
    {
      prs: z
        .array(
          z.object({
            layerName: z.string(),
            prUrl: z.string(),
          }),
        )
        .describe("Array of layer name + PR URL pairs"),
    },
    async ({ prs }) => {
      try {
        const { config } = requireConfig(state);

        for (const pr of prs) {
          const cwd = getLayerCwd(state, pr.layerName);
          const gitInfo = config.gitInfo[pr.layerName];
          if (!gitInfo) continue;

          const existingBody = await getPRBody(cwd, gitInfo, pr.prUrl);
          const relatedSection = [
            "\n\n### Related PRs",
            ...prs
              .filter((other) => other.layerName !== pr.layerName)
              .map((other) => `- **${other.layerName}**: ${other.prUrl}`),
          ].join("\n");

          await editPRBody(cwd, gitInfo, pr.prUrl, existingBody + relatedSection);
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ crosslinked: prs.length }),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );

  server.tool(
    "forgeplan_rollback",
    "Rollback a work package: close PRs, delete branches, revert status",
    {
      wpId: z.number().describe("Work package ID to rollback"),
    },
    async ({ wpId }) => {
      try {
        const { config, projectRoot } = requireConfig(state);
        const opClient = state.opClient!;

        // Find the run in log
        const run = await findRunByWpId(projectRoot, wpId);
        const results: Array<{
          layer: string;
          prClosed: boolean;
          branchDeleted: boolean;
          error?: string;
        }> = [];

        if (run) {
          for (const layer of run.layers) {
            try {
              const cwd = getLayerCwd(state, layer.name);
              const gitInfo = config.gitInfo[layer.name];

              // Close PR
              let prClosed = false;
              if (layer.pr_url && gitInfo) {
                try {
                  await closePR(cwd, gitInfo, layer.pr_url);
                  prClosed = true;
                } catch {
                  // PR may already be closed
                }
              }

              // Delete branch
              let branchDeleted = false;
              try {
                await gitDeleteBranch(cwd, layer.branch, true);
                branchDeleted = true;
              } catch {
                // Branch may not exist
              }

              results.push({
                layer: layer.name,
                prClosed,
                branchDeleted,
              });
            } catch (err) {
              results.push({
                layer: layer.name,
                prClosed: false,
                branchDeleted: false,
                error: err instanceof Error ? err.message : String(err),
              });
            }
          }
        }

        // Revert WP status
        try {
          const wp = await opClient.fetchWP(wpId);
          const pickupStatus = config.statuses.pickup_status;
          if (pickupStatus) {
            await opClient.updateWPStatus(
              wpId,
              pickupStatus,
              wp.lockVersion,
            );
          }

          // Post rollback comment
          const lines = [
            "## forgeplan Rollback",
            "",
            `Work package #${wpId} has been rolled back.`,
            "",
            "| Layer | PR Closed | Branch Deleted |",
            "|-------|-----------|----------------|",
            ...results.map(
              (r) =>
                `| ${r.layer} | ${r.prClosed ? "Yes" : "No"} | ${r.branchDeleted ? "Yes" : "No"} |`,
            ),
          ];
          await opClient.postComment(wpId, lines.join("\n"));
        } catch {
          // Best-effort status revert
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ wpId, results }, null, 2),
            },
          ],
        };
      } catch (err) {
        return {
          isError: true,
          content: [
            {
              type: "text" as const,
              text: err instanceof Error ? err.message : String(err),
            },
          ],
        };
      }
    },
  );
}
