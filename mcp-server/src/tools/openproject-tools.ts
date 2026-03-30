import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";

function requireConfig(state: ServerState) {
  if (!state.config || !state.opClient) {
    throw new Error(
      "Config not loaded. Call forgeplan_load_config first.",
    );
  }
  return { config: state.config, opClient: state.opClient };
}

export function registerOPTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_claim_wp",
    "Claim a work package (assign to self + set status to in_progress)",
    {
      wpId: z.number().describe("Work package ID"),
      lockVersion: z.number().describe("Current lockVersion for optimistic locking"),
    },
    async ({ wpId, lockVersion }) => {
      try {
        const { config, opClient } = requireConfig(state);
        const statusId = config.statuses.in_progress_status;
        if (!statusId) {
          return {
            isError: true,
            content: [
              {
                type: "text" as const,
                text: "statuses.in_progress_status is not configured",
              },
            ],
          };
        }

        const result = await opClient.updateWPStatus(
          wpId,
          statusId,
          lockVersion,
          true,
        );

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                wpId,
                claimed: true,
                lockVersion: result.lockVersion,
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
    "forgeplan_update_wp_status",
    "Update a work package status",
    {
      wpId: z.number().describe("Work package ID"),
      statusKey: z
        .enum(["in_progress", "success", "partial", "failure", "pickup"])
        .describe("Status key from config"),
      lockVersion: z.number().describe("Current lockVersion"),
    },
    async ({ wpId, statusKey, lockVersion }) => {
      try {
        const { config, opClient } = requireConfig(state);
        const statusMap: Record<string, number | null> = {
          in_progress: config.statuses.in_progress_status,
          success: config.statuses.success_status,
          partial: config.statuses.partial_status,
          failure: config.statuses.failure_status,
          pickup: config.statuses.pickup_status,
        };

        const statusId = statusMap[statusKey];
        if (!statusId) {
          return {
            isError: true,
            content: [
              {
                type: "text" as const,
                text: `statuses.${statusKey}_status is not configured`,
              },
            ],
          };
        }

        const result = await opClient.updateWPStatus(
          wpId,
          statusId,
          lockVersion,
        );

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                wpId,
                statusKey,
                statusId,
                lockVersion: result.lockVersion,
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
    "forgeplan_post_wp_comment",
    "Post a markdown comment on a work package",
    {
      wpId: z.number().describe("Work package ID"),
      markdown: z.string().describe("Comment body in markdown"),
    },
    async ({ wpId, markdown }) => {
      try {
        const { opClient } = requireConfig(state);
        await opClient.postComment(wpId, markdown);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({ wpId, commented: true }),
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
