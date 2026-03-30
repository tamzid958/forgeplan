import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { exec } from "../util/exec.js";
import { appendRunLog } from "../util/logger.js";
import { gitStageAll } from "../git/operations.js";

function requireConfig(state: ServerState) {
  if (!state.config || !state.projectRoot || !state.opClient) {
    throw new Error("Config not loaded. Call forgeplan_load_config first.");
  }
  return {
    config: state.config,
    projectRoot: state.projectRoot,
    opClient: state.opClient,
  };
}

interface StepResult {
  step: string;
  exitCode: number;
  stdout: string;
  stderr: string;
  retries: number;
}

export function registerPipelineTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_run_layer_checks",
    "Run format, lint, pre-commit hooks, tests, and build for a layer with retries",
    {
      layerName: z.string().describe("Layer name from config"),
    },
    async ({ layerName }) => {
      try {
        const { config, projectRoot } = requireConfig(state);
        const layer = config.layers[layerName];
        if (!layer) throw new Error(`Unknown layer: ${layerName}`);
        const cwd = layer.repoRoot ?? projectRoot;

        const steps: StepResult[] = [];
        let overallResult: "SUCCESS" | "PARTIAL" | "FAILURE" = "SUCCESS";

        // Format (up to 3 retries)
        if (layer.formatCmd) {
          const formatResult = await runWithRetries(
            layer.formatCmd,
            cwd,
            3,
          );
          steps.push({ step: "format", ...formatResult });
          if (formatResult.exitCode !== 0) overallResult = "PARTIAL";
        }

        // Lint fix (up to 3 retries)
        if (layer.lintFixCmd) {
          const lintResult = await runWithRetries(
            layer.lintFixCmd,
            cwd,
            3,
          );
          steps.push({ step: "lint", ...lintResult });
          if (lintResult.exitCode !== 0) overallResult = "PARTIAL";
        }

        // Stage after format/lint
        await gitStageAll(cwd);

        // Pre-commit hooks
        if (config.hookConventions.manager) {
          const hookCmd = getPreCommitCommand(
            config.hookConventions.manager,
          );
          if (hookCmd) {
            const hookResult = await runCmd(hookCmd, cwd);
            steps.push({
              step: "pre-commit",
              ...hookResult,
              retries: 0,
            });
            if (hookResult.exitCode !== 0) overallResult = "PARTIAL";
          }
        }

        // Tests (up to 2 retries)
        if (layer.testCmd) {
          const testResult = await runWithRetries(layer.testCmd, cwd, 2);
          steps.push({ step: "test", ...testResult });
          if (testResult.exitCode !== 0) overallResult = "PARTIAL";
        }

        // Build (up to 2 retries)
        if (layer.buildCmd) {
          const buildResult = await runWithRetries(
            layer.buildCmd,
            cwd,
            2,
          );
          steps.push({ step: "build", ...buildResult });
          if (buildResult.exitCode !== 0) {
            overallResult =
              overallResult === "SUCCESS" ? "PARTIAL" : "FAILURE";
          }
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                { layerName, overallResult, steps },
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
    "forgeplan_log_run",
    "Append a run entry to the JSONL log",
    {
      wpId: z.number().describe("Work package ID"),
      result: z.string().describe("Overall result (SUCCESS/PARTIAL/FAILURE)"),
      layers: z
        .array(
          z.object({
            name: z.string(),
            branch: z.string(),
            prUrl: z.string(),
            result: z.string(),
          }),
        )
        .describe("Per-layer results"),
    },
    async ({ wpId, result, layers }) => {
      try {
        const { projectRoot } = requireConfig(state);

        await appendRunLog(projectRoot, {
          wp_id: wpId,
          result,
          layers: layers.map((l) => ({
            name: l.name,
            branch: l.branch,
            pr_url: l.prUrl,
            result: l.result,
          })),
          timestamp: new Date().toISOString(),
        });

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ logged: true, wpId, result }),
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
    "forgeplan_finish_wp",
    "Finalize a work package: aggregate results, update OP status, post summary, log run",
    {
      wpId: z.number().describe("Work package ID"),
      lockVersion: z.number().describe("Current lockVersion"),
      layerResults: z
        .array(
          z.object({
            name: z.string(),
            result: z.string(),
            branch: z.string(),
            prUrl: z.string(),
          }),
        )
        .describe("Per-layer results"),
    },
    async ({ wpId, lockVersion, layerResults }) => {
      try {
        const { config, projectRoot, opClient } = requireConfig(state);

        // Aggregate
        const allSuccess = layerResults.every(
          (l) => l.result === "SUCCESS",
        );
        const anyFailure = layerResults.some(
          (l) => l.result === "FAILURE",
        );
        const anySuccess = layerResults.some(
          (l) => l.result === "SUCCESS" || l.result === "PARTIAL",
        );

        let overallResult: string;
        if (allSuccess) {
          overallResult = "SUCCESS";
        } else if (anyFailure && !anySuccess) {
          overallResult = "FAILURE";
        } else {
          overallResult = "PARTIAL";
        }

        // Update OP status
        const statusMap: Record<string, number | null> = {
          SUCCESS: config.statuses.success_status,
          PARTIAL: config.statuses.partial_status,
          FAILURE: config.statuses.failure_status,
        };
        const statusId = statusMap[overallResult];
        let newLockVersion = lockVersion;
        if (statusId) {
          const updateResult = await opClient.updateWPStatus(
            wpId,
            statusId,
            lockVersion,
          );
          newLockVersion = updateResult.lockVersion;
        }

        // Post summary comment
        const opUrl = config.openproject.url.replace(/\/+$/, "");
        const commentLines = [
          "## forgeplan Report",
          "",
          "| Layer | Result | Branch | PR |",
          "|-------|--------|--------|----|",
          ...layerResults.map(
            (l) =>
              `| ${l.name} | ${l.result} | \`${l.branch}\` | ${l.prUrl ? `[PR](${l.prUrl})` : "N/A"} |`,
          ),
          "",
          `**Overall:** ${overallResult}`,
          "",
          "Generated by forgeplan (MCP server)",
        ];
        await opClient.postComment(wpId, commentLines.join("\n"));

        // Log run
        await appendRunLog(projectRoot, {
          wp_id: wpId,
          result: overallResult,
          layers: layerResults.map((l) => ({
            name: l.name,
            branch: l.branch,
            pr_url: l.prUrl,
            result: l.result,
          })),
          timestamp: new Date().toISOString(),
        });

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                wpId,
                overallResult,
                lockVersion: newLockVersion,
                commented: true,
                logged: true,
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
}

async function runCmd(
  cmd: string,
  cwd: string,
): Promise<{ exitCode: number; stdout: string; stderr: string }> {
  const parts = cmd.split(/\s+/);
  const result = await exec(parts[0], parts.slice(1), { cwd });
  return {
    exitCode: result.exitCode,
    stdout: result.stdout,
    stderr: result.stderr,
  };
}

async function runWithRetries(
  cmd: string,
  cwd: string,
  maxRetries: number,
): Promise<{
  exitCode: number;
  stdout: string;
  stderr: string;
  retries: number;
}> {
  let lastResult = await runCmd(cmd, cwd);
  let retries = 0;

  while (lastResult.exitCode !== 0 && retries < maxRetries) {
    retries++;
    lastResult = await runCmd(cmd, cwd);
  }

  return { ...lastResult, retries };
}

function getPreCommitCommand(manager: string): string | null {
  switch (manager) {
    case "lefthook":
      return "lefthook run pre-commit";
    case "pre-commit":
      return "pre-commit run --all-files";
    case "husky":
      return null; // Husky hooks are file-based, handled differently
    default:
      return null;
  }
}
