import { z } from "zod";
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { existsSync } from "node:fs";
import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import type { ServerState } from "../index.js";
import { exec } from "../util/exec.js";

interface LayerProbe {
  name: string;
  path: string;
  techStack: string;
  filePatterns: string[];
  buildCmd: string;
  testCmd: string | null;
  lintFixCmd: string | null;
  formatCmd: string | null;
  repoRoot: string | null;
}

interface HookProbe {
  manager: string | null;
  configFile: string | null;
  branchFormat: string;
  commitSubjectMaxLength: number;
  testParityRequired: boolean;
  testFilePattern: string | null;
}

interface ToolProbe {
  name: string;
  path: string | null;
  found: boolean;
}

export function registerInitTools(
  server: McpServer,
  _state: ServerState,
): void {
  server.tool(
    "forgeplan_init_probe",
    "Scan a project directory to auto-detect layers, tech stacks, tools, hooks, and git repos",
    {
      projectRoot: z.string().describe("Absolute path to project root"),
      layerPaths: z
        .array(z.string())
        .describe('Relative paths to layers (e.g. ["src/backend", "src/frontend"] or ["."])'),
    },
    async ({ projectRoot, layerPaths }) => {
      try {
        const layers: LayerProbe[] = [];
        const repoRoots = new Set<string>();

        for (const rel of layerPaths) {
          const absPath = rel === "." ? projectRoot : join(projectRoot, rel);
          const name =
            rel === "." ? "app" : rel.split("/").pop() ?? rel;

          // Detect repo root
          const repoResult = await exec(
            "git",
            ["-C", absPath, "rev-parse", "--show-toplevel"],
          );
          const repoRoot =
            repoResult.exitCode === 0
              ? repoResult.stdout.trim()
              : null;
          if (repoRoot) repoRoots.add(repoRoot);

          // Detect tech stack
          const detected = await detectTechStack(absPath);

          layers.push({
            name,
            path: rel === "." ? "." : rel,
            techStack: detected.techStack,
            filePatterns: detected.filePatterns,
            buildCmd: detected.buildCmd,
            testCmd: detected.testCmd,
            lintFixCmd: detected.lintFixCmd,
            formatCmd: detected.formatCmd,
            repoRoot:
              repoRoots.size > 1 ? repoRoot : null,
          });
        }

        // Detect hooks from first repo root
        const primaryRepo =
          [...repoRoots][0] ?? projectRoot;
        const hooks = await detectHooks(primaryRepo);

        // Detect tools
        const toolNames = new Set<string>(["git", "gh", "glab"]);
        for (const layer of layers) {
          for (const t of techStackTools(layer.techStack)) {
            toolNames.add(t);
          }
        }
        const tools: ToolProbe[] = [];
        for (const name of toolNames) {
          const result = await exec("which", [name]);
          tools.push({
            name,
            path:
              result.exitCode === 0
                ? result.stdout.trim()
                : null,
            found: result.exitCode === 0,
          });
        }

        // Check for existing configs
        const hasConfig = existsSync(
          join(projectRoot, "forgeplan.config.json"),
        );
        const hasLocal = existsSync(
          join(projectRoot, "forgeplan.local.json"),
        );
        const hasEnv = existsSync(join(projectRoot, ".env"));

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  layers,
                  hooks,
                  tools,
                  repoRoots: [...repoRoots],
                  multiRepo: repoRoots.size > 1,
                  existingFiles: {
                    "forgeplan.config.json": hasConfig,
                    "forgeplan.local.json": hasLocal,
                    ".env": hasEnv,
                  },
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
    "forgeplan_init_discover_statuses",
    "Connect to OpenProject and fetch available statuses for mapping",
    {
      opUrl: z.string().describe("OpenProject instance URL"),
      apiKey: z.string().describe("OpenProject API key"),
      projectId: z.string().describe("Project slug"),
    },
    async ({ opUrl, apiKey, projectId }) => {
      try {
        const baseUrl = opUrl.replace(/\/+$/, "");
        const authHeader = `Basic ${Buffer.from(`apikey:${apiKey}`).toString("base64")}`;

        // Verify connection
        const rootRes = await fetch(`${baseUrl}/api/v3`, {
          headers: {
            Accept: "application/hal+json",
            Authorization: authHeader,
          },
        });
        if (!rootRes.ok) {
          return {
            isError: true,
            content: [
              {
                type: "text" as const,
                text: `OpenProject connection failed: HTTP ${rootRes.status}${rootRes.status === 401 ? " — check API key" : ""}`,
              },
            ],
          };
        }

        // Verify project
        const projectRes = await fetch(
          `${baseUrl}/api/v3/projects/${projectId}`,
          {
            headers: {
              Accept: "application/hal+json",
              Authorization: authHeader,
            },
          },
        );
        if (!projectRes.ok) {
          return {
            isError: true,
            content: [
              {
                type: "text" as const,
                text: `Project "${projectId}" not found (HTTP ${projectRes.status})`,
              },
            ],
          };
        }

        // Fetch current user
        const userRes = await fetch(`${baseUrl}/api/v3/users/me`, {
          headers: {
            Accept: "application/hal+json",
            Authorization: authHeader,
          },
        });
        const userData = (await userRes.json()) as {
          id: number;
          name: string;
        };

        // Fetch statuses
        const statusRes = await fetch(`${baseUrl}/api/v3/statuses`, {
          headers: {
            Accept: "application/hal+json",
            Authorization: authHeader,
          },
        });
        const statusData = (await statusRes.json()) as {
          _embedded: {
            elements: Array<{ id: number; name: string }>;
          };
        };
        const statuses = statusData._embedded.elements.map((s) => ({
          id: s.id,
          name: s.name,
        }));

        // Suggest mappings based on name patterns
        const suggestions: Record<string, number | null> = {
          pickup_status: null,
          in_progress_status: null,
          success_status: null,
          partial_status: null,
          failure_status: null,
        };
        for (const s of statuses) {
          const n = s.name.toLowerCase();
          if (
            !suggestions.pickup_status &&
            (n.includes("new") ||
              n.includes("ready") ||
              n.includes("todo") ||
              n.includes("to do"))
          )
            suggestions.pickup_status = s.id;
          if (
            !suggestions.in_progress_status &&
            n.includes("in progress")
          )
            suggestions.in_progress_status = s.id;
          if (
            !suggestions.success_status &&
            (n.includes("review") ||
              n.includes("done") ||
              n.includes("resolved"))
          )
            suggestions.success_status = s.id;
          if (
            !suggestions.partial_status &&
            n.includes("in progress")
          )
            suggestions.partial_status = s.id;
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify(
                {
                  connected: true,
                  user: { id: userData.id, name: userData.name },
                  statuses,
                  suggestedMappings: suggestions,
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
    "forgeplan_init_write_config",
    "Write forgeplan config files (.env, forgeplan.config.json, forgeplan.local.json)",
    {
      projectRoot: z.string().describe("Absolute path to project root"),
      apiKey: z.string().describe("OpenProject API key"),
      config: z
        .string()
        .describe("JSON string for forgeplan.config.json"),
      local: z
        .string()
        .describe("JSON string for forgeplan.local.json"),
    },
    async ({ projectRoot, apiKey, config, local }) => {
      try {
        // Validate JSON before writing
        JSON.parse(config);
        JSON.parse(local);

        // Write .env
        const envPath = join(projectRoot, ".env");
        await writeFile(envPath, `OP_API_KEY=${apiKey}\n`, "utf-8");

        // Write forgeplan.config.json
        const configPath = join(projectRoot, "forgeplan.config.json");
        await writeFile(
          configPath,
          JSON.stringify(JSON.parse(config), null, 2) + "\n",
          "utf-8",
        );

        // Write forgeplan.local.json
        const localPath = join(projectRoot, "forgeplan.local.json");
        await writeFile(
          localPath,
          JSON.stringify(JSON.parse(local), null, 2) + "\n",
          "utf-8",
        );

        // Ensure .gitignore has the right entries
        const gitignorePath = join(projectRoot, ".gitignore");
        const requiredEntries = [".env", "forgeplan.local.json", "logs/"];
        let gitignoreContent = "";
        if (existsSync(gitignorePath)) {
          const { readFile } = await import("node:fs/promises");
          gitignoreContent = await readFile(gitignorePath, "utf-8");
        }
        const missing = requiredEntries.filter(
          (e) => !gitignoreContent.includes(e),
        );
        if (missing.length > 0) {
          const addition =
            (gitignoreContent.endsWith("\n") ? "" : "\n") +
            "\n# forgeplan\n" +
            missing.join("\n") +
            "\n";
          await writeFile(
            gitignorePath,
            gitignoreContent + addition,
            "utf-8",
          );
        }

        return {
          content: [
            {
              type: "text" as const,
              text: JSON.stringify({
                written: [
                  ".env",
                  "forgeplan.config.json",
                  "forgeplan.local.json",
                ],
                gitignoreUpdated: missing.length > 0,
                gitignoreAdded: missing,
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

// --- Detection helpers ---

async function detectTechStack(dir: string): Promise<{
  techStack: string;
  filePatterns: string[];
  buildCmd: string;
  testCmd: string | null;
  lintFixCmd: string | null;
  formatCmd: string | null;
}> {
  // Node.js / Next.js / React
  if (existsSync(join(dir, "package.json"))) {
    const { readFile } = await import("node:fs/promises");
    const raw = await readFile(join(dir, "package.json"), "utf-8");
    const pkg = JSON.parse(raw);
    const deps = {
      ...pkg.dependencies,
      ...pkg.devDependencies,
    };
    const scripts = pkg.scripts ?? {};

    let techStack = "node";
    const filePatterns = ["**/*.ts", "**/*.tsx", "**/*.js", "**/*.jsx"];

    if (deps.next) techStack = "nextjs";
    else if (deps.react) techStack = "react";
    else if (deps.vue) techStack = "vue";
    else if (deps.svelte || deps["@sveltejs/kit"]) techStack = "svelte";
    else if (deps["@angular/core"]) techStack = "angular";

    const buildCmd = scripts.build ? "npm run build" : "npx tsc";
    const testCmd = scripts.test ? "npm test" : null;
    const lintFixCmd = deps.eslint ? "npx eslint --fix ." : null;
    const formatCmd = deps.prettier ? "npx prettier --write ." : null;

    return { techStack, filePatterns, buildCmd, testCmd, lintFixCmd, formatCmd };
  }

  // .NET
  const csprojCheck = await exec("find", [dir, "-maxdepth", "2", "-name", "*.csproj", "-print", "-quit"]);
  if (csprojCheck.stdout.trim()) {
    const testCsproj = await exec("find", [dir, "-maxdepth", "3", "-name", "*Test*.csproj", "-print", "-quit"]);
    return {
      techStack: "dotnet",
      filePatterns: ["**/*.cs", "**/*.csproj"],
      buildCmd: "dotnet build",
      testCmd: testCsproj.stdout.trim() ? "dotnet test" : null,
      lintFixCmd: "dotnet format",
      formatCmd: null,
    };
  }

  // Go
  if (existsSync(join(dir, "go.mod"))) {
    return {
      techStack: "go",
      filePatterns: ["**/*.go"],
      buildCmd: "go build ./...",
      testCmd: "go test ./...",
      lintFixCmd: null,
      formatCmd: "gofmt -w .",
    };
  }

  // Rust
  if (existsSync(join(dir, "Cargo.toml"))) {
    return {
      techStack: "rust",
      filePatterns: ["**/*.rs"],
      buildCmd: "cargo build",
      testCmd: "cargo test",
      lintFixCmd: null,
      formatCmd: "cargo fmt",
    };
  }

  // Flutter
  if (existsSync(join(dir, "pubspec.yaml"))) {
    return {
      techStack: "flutter",
      filePatterns: ["**/*.dart"],
      buildCmd: "flutter build",
      testCmd: "flutter test",
      lintFixCmd: "dart fix --apply",
      formatCmd: "dart format .",
    };
  }

  // Python
  if (
    existsSync(join(dir, "pyproject.toml")) ||
    existsSync(join(dir, "setup.py")) ||
    existsSync(join(dir, "requirements.txt"))
  ) {
    return {
      techStack: "python",
      filePatterns: ["**/*.py"],
      buildCmd: "python -m py_compile .",
      testCmd: "pytest",
      lintFixCmd: "ruff check --fix .",
      formatCmd: "ruff format .",
    };
  }

  return {
    techStack: "unknown",
    filePatterns: ["**/*"],
    buildCmd: "echo 'no build command detected'",
    testCmd: null,
    lintFixCmd: null,
    formatCmd: null,
  };
}

async function detectHooks(repoRoot: string): Promise<HookProbe> {
  const result: HookProbe = {
    manager: null,
    configFile: null,
    branchFormat: "{type}/WP-{id}-{slug}",
    commitSubjectMaxLength: 72,
    testParityRequired: false,
    testFilePattern: null,
  };

  if (existsSync(join(repoRoot, "lefthook.yml"))) {
    result.manager = "lefthook";
    result.configFile = "lefthook.yml";
  } else if (existsSync(join(repoRoot, ".husky", "pre-commit"))) {
    result.manager = "husky";
    result.configFile = ".husky/pre-commit";
  } else if (existsSync(join(repoRoot, ".pre-commit-config.yaml"))) {
    result.manager = "pre-commit";
    result.configFile = ".pre-commit-config.yaml";
  }

  // Detect test file patterns
  const testDirCheck = await exec("find", [
    repoRoot,
    "-maxdepth", "4",
    "-type", "d",
    "-name", "__tests__",
    "-print",
    "-quit",
  ]);
  if (testDirCheck.stdout.trim()) {
    result.testParityRequired = true;
    result.testFilePattern = "__tests__/{path}/{name}.test.{ext}";
  } else {
    const testFileCheck = await exec("find", [
      repoRoot,
      "-maxdepth", "4",
      "-name", "*.test.*",
      "-not", "-path", "*/node_modules/*",
      "-print",
      "-quit",
    ]);
    if (testFileCheck.stdout.trim()) {
      result.testFilePattern = "{dir}/{name}.test.{ext}";
    }
  }

  return result;
}

function techStackTools(techStack: string): string[] {
  switch (techStack.toLowerCase()) {
    case "dotnet":
      return ["dotnet"];
    case "nextjs":
    case "react":
    case "vue":
    case "svelte":
    case "angular":
    case "node":
      return ["node", "npm"];
    case "flutter":
      return ["flutter", "dart"];
    case "go":
      return ["go"];
    case "rust":
      return ["cargo"];
    case "python":
      return ["python"];
    default:
      return [];
  }
}
