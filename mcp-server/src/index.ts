import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerConfigTools } from "./tools/config-tools.js";
import { registerWPTools } from "./tools/wp-tools.js";
import { registerOPTools } from "./tools/openproject-tools.js";
import { registerRoutingTools } from "./tools/routing-tools.js";
import { registerGitTools } from "./tools/git-tools.js";
import { registerPipelineTools } from "./tools/pipeline-tools.js";
import { registerResources } from "./resources/index.js";
import { registerPrompts } from "./prompts/index.js";
import type { MergedConfig } from "./config/types.js";
import type { OpenProjectClient } from "./openproject/client.js";

export interface ServerState {
  config: MergedConfig | null;
  opClient: OpenProjectClient | null;
  projectRoot: string | null;
}

export function createServer(): McpServer {
  const server = new McpServer({
    name: "forgeplan",
    version: "0.1.0",
  });

  const state: ServerState = {
    config: null,
    opClient: null,
    projectRoot: null,
  };

  registerConfigTools(server, state);
  registerWPTools(server, state);
  registerOPTools(server, state);
  registerRoutingTools(server, state);
  registerGitTools(server, state);
  registerPipelineTools(server, state);
  registerResources(server, state);
  registerPrompts(server, state);

  return server;
}
