import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { evaluateQualityGate } from "../openproject/client.js";

function requireConfig(state: ServerState) {
  if (!state.config || !state.opClient) {
    throw new Error(
      "Config not loaded. Call forgeplan_load_config first.",
    );
  }
  return { config: state.config, opClient: state.opClient };
}

export function registerWPTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_fetch_wp",
    "Fetch a work package and evaluate its quality gate",
    { wpId: z.number().describe("OpenProject work package ID") },
    async ({ wpId }) => {
      try {
        const { opClient } = requireConfig(state);
        const wp = await opClient.fetchWP(wpId);
        const wpType = wp._links?.type?.title ?? "Task";
        const wpContext = await opClient.fetchWPContext(wpId);
        const qualityGate = evaluateQualityGate(wp, wpContext, wpType);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  id: wp.id,
                  subject: wp.subject,
                  lockVersion: wp.lockVersion,
                  type: wpType,
                  priority: wp._links?.priority?.title ?? "",
                  status: wp._links?.status?.title ?? "",
                  description: wp.description?.raw ?? "",
                  category: wp._links?.category?.title ?? null,
                  parentHref: wp._links?.parent?.href ?? null,
                  assignee: wp._links?.assignee?.title ?? null,
                  qualityGate,
                },
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
    "forgeplan_fetch_wp_context",
    "Fetch full context bundle for a work package (parents, siblings, children, relations, comments)",
    { wpId: z.number().describe("OpenProject work package ID") },
    async ({ wpId }) => {
      try {
        const { opClient } = requireConfig(state);
        const context = await opClient.fetchWPContext(wpId);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(context, null, 2),
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
    "forgeplan_list_sprint",
    "List work packages for a sprint/version",
    {
      sprintName: z
        .string()
        .optional()
        .describe("Sprint/version name (omit for current)"),
    },
    async ({ sprintName }) => {
      try {
        const { config, opClient } = requireConfig(state);
        const wps = await opClient.fetchSprintWPs(
          config.openproject.projectId,
          sprintName,
        );

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(wps, null, 2),
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
    "forgeplan_wp_detail",
    "Fetch a work package with full hierarchy tree",
    { wpId: z.number().describe("OpenProject work package ID") },
    async ({ wpId }) => {
      try {
        const { opClient } = requireConfig(state);
        const wp = await opClient.fetchWP(wpId);
        const context = await opClient.fetchWPContext(wpId);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  id: wp.id,
                  subject: wp.subject,
                  type: wp._links?.type?.title ?? "",
                  status: wp._links?.status?.title ?? "",
                  description: wp.description?.raw ?? "",
                  parents: context.parents.map((p) => ({
                    id: p.id,
                    subject: p.subject,
                    type: p._links?.type?.title ?? "",
                  })),
                  children: context.children,
                  siblings: context.siblings,
                  relations: context.relations,
                },
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
    "forgeplan_discover_queue",
    "Discover ready work packages (assigned-to-you first, then unassigned)",
    {},
    async () => {
      try {
        const { config, opClient } = requireConfig(state);
        const pickupStatus = config.statuses.pickup_status;
        if (!pickupStatus) {
          return {
            isError: true,
            content: [
              {
                type: "text" as const,
                text: "statuses.pickup_status is not configured",
              },
            ],
          };
        }

        const assigneeFilter = config.userId
          ? String(config.userId)
          : "me";
        const [assigned, unassigned] = await Promise.all([
          opClient.queryByStatus(
            config.openproject.projectId,
            pickupStatus,
            assigneeFilter,
          ),
          opClient.queryByStatus(
            config.openproject.projectId,
            pickupStatus,
          ),
        ]);

        // Deduplicate: remove assigned WPs from unassigned list
        const assignedIds = new Set(assigned.map((w) => w.id));
        const rest = unassigned.filter((w) => !assignedIds.has(w.id));

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  assigned,
                  unassigned: rest,
                  total: assigned.length + rest.length,
                },
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
}
