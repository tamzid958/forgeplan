import { z } from "zod";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { loadConfig, getApiKey } from "../config/loader.js";
import { validateConfig } from "../config/validator.js";
import { OpenProjectClient } from "../openproject/client.js";
import { exec } from "../util/exec.js";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

export function registerConfigTools(
  server: McpServer,
  state: ServerState,
): void {
  server.tool(
    "forgeplan_load_config",
    "Load and validate forgeplan configuration from project root",
    { projectRoot: z.string().describe("Absolute path to project root") },
    async ({ projectRoot }) => {
      try {
        const config = await loadConfig(projectRoot);
        const validation = validateConfig(config);

        state.config = config;
        state.projectRoot = projectRoot;
        state.opClient = new OpenProjectClient(
          config.openproject.url,
          getApiKey(),
        );

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  config: {
                    openproject: config.openproject,
                    layers: Object.fromEntries(
                      Object.entries(config.layers).map(([name, layer]) => [
                        name,
                        {
                          path: layer.path,
                          techStack: layer.techStack,
                          buildCmd: layer.buildCmd,
                        },
                      ]),
                    ),
                    routing: config.routing,
                    reviewers: config.reviewers,
                    statuses: config.statuses,
                    hookConventions: config.hookConventions,
                    gitInfo: config.gitInfo,
                  },
                  validation,
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
    "forgeplan_doctor",
    "Run diagnostic health checks on forgeplan setup",
    { projectRoot: z.string().describe("Absolute path to project root") },
    async ({ projectRoot }) => {
      const checks: Array<{
        name: string;
        status: "pass" | "warn" | "fail";
        details: string;
      }> = [];

      // Check 1: Dependencies
      const deps = [
        { name: "git", required: true },
        { name: "gh", required: false },
        { name: "glab", required: false },
      ];

      let hasGhOrGlab = false;
      for (const dep of deps) {
        const result = await exec("which", [dep.name]);
        if (result.exitCode === 0) {
          const versionResult = await exec(dep.name, ["--version"]);
          const version = versionResult.stdout.trim().split("\n")[0];
          checks.push({
            name: `Dependency: ${dep.name}`,
            status: "pass",
            details: version,
          });
          if (dep.name === "gh" || dep.name === "glab") hasGhOrGlab = true;
        } else if (dep.required) {
          checks.push({
            name: `Dependency: ${dep.name}`,
            status: "fail",
            details: `${dep.name} not found in PATH`,
          });
        } else {
          checks.push({
            name: `Dependency: ${dep.name}`,
            status: "warn",
            details: `${dep.name} not found (needed for PRs)`,
          });
        }
      }
      if (!hasGhOrGlab) {
        checks.push({
          name: "Dependency: gh/glab",
          status: "fail",
          details: "At least one of gh or glab must be installed",
        });
      }

      // Check 2: Config validation
      const configPath = join(projectRoot, "forgeplan.config.json");
      if (!existsSync(configPath)) {
        checks.push({
          name: "Config (shared)",
          status: "fail",
          details: "forgeplan.config.json not found. Run /forgeplan init",
        });
      } else {
        try {
          const raw = await readFile(configPath, "utf-8");
          JSON.parse(raw);
          checks.push({
            name: "Config (shared)",
            status: "pass",
            details: "forgeplan.config.json valid JSON",
          });
        } catch {
          checks.push({
            name: "Config (shared)",
            status: "fail",
            details: "forgeplan.config.json has invalid JSON syntax",
          });
        }
      }

      const localPath = join(projectRoot, "forgeplan.local.json");
      if (!existsSync(localPath)) {
        checks.push({
          name: "Config (local)",
          status: "warn",
          details:
            "forgeplan.local.json not found. Run /forgeplan init to detect toolchain",
        });
      } else {
        checks.push({
          name: "Config (local)",
          status: "pass",
          details: "forgeplan.local.json present",
        });
      }

      // Check 3: API key
      const envPath = join(projectRoot, ".env");
      if (existsSync(envPath)) {
        try {
          const envContent = await readFile(envPath, "utf-8");
          const hasKey = envContent
            .split("\n")
            .some(
              (line) =>
                line.startsWith("OP_API_KEY=") &&
                line.replace("OP_API_KEY=", "").trim().length > 0,
            );
          checks.push({
            name: "API Key",
            status: hasKey ? "pass" : "fail",
            details: hasKey ? "OP_API_KEY loaded from .env" : "OP_API_KEY is empty in .env",
          });
        } catch {
          checks.push({
            name: "API Key",
            status: "fail",
            details: "Could not read .env file",
          });
        }
      } else {
        checks.push({
          name: "API Key",
          status: "fail",
          details: ".env file not found",
        });
      }

      // Check 4: Toolchain (attempt to load config for layer tools)
      try {
        const config = await loadConfig(projectRoot);
        const validation = validateConfig(config);

        if (validation.valid) {
          checks.push({
            name: "Config validation",
            status: "pass",
            details: "All required fields present",
          });
        } else {
          for (const err of validation.errors) {
            checks.push({
              name: "Config validation",
              status: "fail",
              details: err,
            });
          }
        }
        for (const warn of validation.warnings) {
          checks.push({
            name: "Config validation",
            status: "warn",
            details: warn,
          });
        }

        // Check 5: OpenProject connectivity
        try {
          const apiKey = getApiKey();
          const opUrl = config.openproject.url.replace(/\/+$/, "");
          const res = await fetch(`${opUrl}/api/v3`, {
            headers: {
              Accept: "application/hal+json",
              Authorization: `Basic ${Buffer.from(`apikey:${apiKey}`).toString("base64")}`,
            },
          });
          if (res.ok) {
            checks.push({
              name: "OpenProject",
              status: "pass",
              details: `Connected to ${config.openproject.projectId}`,
            });
          } else if (res.status === 401 || res.status === 403) {
            checks.push({
              name: "OpenProject",
              status: "fail",
              details: `Auth failed (HTTP ${res.status}) — check API key`,
            });
          } else {
            checks.push({
              name: "OpenProject",
              status: "warn",
              details: `HTTP ${res.status} from ${opUrl}`,
            });
          }
        } catch (err) {
          checks.push({
            name: "OpenProject",
            status: "fail",
            details: `Unreachable: ${err instanceof Error ? err.message : String(err)}`,
          });
        }

        // Check 6: Repository (per layer)
        for (const [name, layer] of Object.entries(config.layers)) {
          const cwd = layer.repoRoot ?? projectRoot;
          const gitCheck = await exec("git", ["rev-parse", "--git-dir"], {
            cwd,
          });
          if (gitCheck.exitCode === 0) {
            const remoteCheck = await exec(
              "git",
              ["remote", "get-url", "origin"],
              { cwd },
            );
            checks.push({
              name: `Repository: ${name}`,
              status: "pass",
              details: remoteCheck.stdout.trim() || "git repo found",
            });
          } else {
            checks.push({
              name: `Repository: ${name}`,
              status: "fail",
              details: `${cwd} is not a git repository`,
            });
          }
        }

        // Check 7: Hook conventions
        if (config.hookConventions.manager) {
          const managerCheck = await exec("which", [
            config.hookConventions.manager,
          ]);
          checks.push({
            name: "Hooks",
            status: managerCheck.exitCode === 0 ? "pass" : "warn",
            details:
              managerCheck.exitCode === 0
                ? `${config.hookConventions.manager} installed`
                : `${config.hookConventions.manager} not found in PATH`,
          });
        } else {
          checks.push({
            name: "Hooks",
            status: "warn",
            details: "No hook manager configured",
          });
        }

        // Check 8: Git auth
        for (const [name, info] of Object.entries(config.gitInfo)) {
          if (info.hostType === "github") {
            const authCheck = await exec("gh", ["auth", "status"]);
            checks.push({
              name: `Git Auth: ${name}`,
              status: authCheck.exitCode === 0 ? "pass" : "fail",
              details:
                authCheck.exitCode === 0
                  ? "GitHub authenticated"
                  : "GitHub auth failed — run `gh auth login`",
            });
          } else if (info.hostType === "gitlab") {
            const authCheck = await exec("glab", ["auth", "status"]);
            checks.push({
              name: `Git Auth: ${name}`,
              status: authCheck.exitCode === 0 ? "pass" : "fail",
              details:
                authCheck.exitCode === 0
                  ? "GitLab authenticated"
                  : "GitLab auth failed — run `glab auth login`",
            });
          }
        }
      } catch (err) {
        checks.push({
          name: "Config load",
          status: "fail",
          details: err instanceof Error ? err.message : String(err),
        });
      }

      // Format summary
      const passed = checks.filter((c) => c.status === "pass").length;
      const warned = checks.filter((c) => c.status === "warn").length;
      const failed = checks.filter((c) => c.status === "fail").length;

      const icons = { pass: "\u2713", warn: "\u26a0", fail: "\u2717" };
      const lines = checks.map(
        (c) => `  ${icons[c.status]} ${c.name}: ${c.details}`,
      );

      const summary = [
        "forgeplan doctor",
        "\u2550".repeat(50),
        ...lines,
        "\u2550".repeat(50),
        `  Result: ${passed} passed, ${warned} warnings, ${failed} failures`,
      ].join("\n");

      return {
        content: [{ type: "text" as const, text: summary }],
      };
    },
  );
}
