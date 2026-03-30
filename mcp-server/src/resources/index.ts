import { readFile } from "node:fs/promises";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { readRunLog } from "../util/logger.js";

const TYPE_TO_FILE: Record<string, string> = {
  bug: "bug-rules.md",
  feature: "feature-rules.md",
  epic: "epic-rules.md",
  story: "story-rules.md",
  "user story": "story-rules.md",
  subtask: "subtask-rules.md",
  task: "task-rules.md",
};

const VALID_WP_TYPES = new Set(Object.keys(TYPE_TO_FILE));

function getPromptsDir(): string {
  // Resolve relative to the mcp-server package, up to forgeplan root
  const thisFile = fileURLToPath(import.meta.url);
  const serverRoot = dirname(dirname(dirname(thisFile)));
  return join(dirname(serverRoot), "prompts");
}

export function registerResources(
  server: McpServer,
  state: ServerState,
): void {
  // Resource template: forgeplan://rules/{wpType}
  server.resource(
    "rules",
    "forgeplan://rules/{wpType}",
    {
      description:
        "Generation rules for a work package type (bug, feature, epic, story, subtask, task)",
      mimeType: "text/markdown",
    },
    async (uri) => {
      const wpType = uri.pathname.split("/").pop()?.toLowerCase() ?? "";

      if (!VALID_WP_TYPES.has(wpType)) {
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "text/plain",
              text: `Unknown WP type: "${wpType}". Valid types: ${[...VALID_WP_TYPES].join(", ")}`,
            },
          ],
        };
      }

      const promptsDir = getPromptsDir();
      try {
        const [baseRules, typeRules] = await Promise.all([
          readFile(join(promptsDir, "_base.md"), "utf-8"),
          readFile(join(promptsDir, TYPE_TO_FILE[wpType]), "utf-8"),
        ]);

        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "text/markdown",
              text: `${baseRules}\n\n---\n\n${typeRules}`,
            },
          ],
        };
      } catch {
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "text/plain",
              text: `Could not read rules files from ${promptsDir}`,
            },
          ],
        };
      }
    },
  );

  // Resource: forgeplan://config
  server.resource(
    "config",
    "forgeplan://config",
    {
      description: "Current merged forgeplan configuration (sanitized, no API key)",
      mimeType: "application/json",
    },
    async (uri) => {
      if (!state.config) {
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "text/plain",
              text: "Config not loaded. Call forgeplan_load_config first.",
            },
          ],
        };
      }

      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "application/json",
            text: JSON.stringify(state.config, null, 2),
          },
        ],
      };
    },
  );

  // Resource: forgeplan://log
  server.resource(
    "log",
    "forgeplan://log",
    {
      description: "Run summary log (JSONL format)",
      mimeType: "application/jsonl",
    },
    async (uri) => {
      if (!state.projectRoot) {
        return {
          contents: [
            {
              uri: uri.href,
              mimeType: "text/plain",
              text: "",
            },
          ],
        };
      }

      const entries = await readRunLog(state.projectRoot);
      const text = entries.map((e) => JSON.stringify(e)).join("\n");

      return {
        contents: [
          {
            uri: uri.href,
            mimeType: "application/jsonl",
            text: text || "",
          },
        ],
      };
    },
  );
}
