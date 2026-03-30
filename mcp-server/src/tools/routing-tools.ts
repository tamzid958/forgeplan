import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { routeWP } from "../routing/layer-router.js";
import type { WorkPackage } from "../openproject/types.js";

function requireConfig(state: ServerState) {
  if (!state.config) {
    throw new Error("Config not loaded. Call forgeplan_load_config first.");
  }
  return state.config;
}

export function registerRoutingTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_route_wp",
    "Route a work package to target layer(s) via config routing rules",
    {
      wpId: z.number().describe("Work package ID"),
      wpType: z.string().describe("Work package type (Bug, Feature, etc.)"),
      category: z.string().optional().describe("Category field value"),
      subject: z.string().describe("Work package subject"),
      description: z.string().describe("Work package description"),
    },
    async ({ wpId, wpType, category, subject, description }) => {
      try {
        const config = requireConfig(state);

        // Build a minimal WP object for routing
        const wp: WorkPackage = {
          id: wpId,
          subject,
          lockVersion: 0,
          description: { raw: description },
          _links: {
            type: { title: wpType, href: "" },
            category: category
              ? { title: category, href: "" }
              : undefined,
          },
        };

        const result = routeWP(config, wp);

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  layers: result.layers.map((l) => ({
                    name: l.name,
                    path: l.config.path,
                    techStack: l.config.techStack,
                  })),
                  method: result.method,
                  needsConfirmation: result.needsConfirmation,
                  warnings: result.warnings,
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
