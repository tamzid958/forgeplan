import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { config as loadDotenv } from "dotenv";
import { exec } from "../util/exec.js";
import { deepMerge } from "../util/merge.js";
import type {
  ForgeplanConfig,
  LocalConfig,
  MergedConfig,
  GitInfo,
  HookConventions,
} from "./types.js";

let storedApiKey: string | null = null;

export function getApiKey(): string {
  if (!storedApiKey) {
    throw new Error("API key not loaded. Call loadConfig first.");
  }
  return storedApiKey;
}

export async function loadConfig(projectRoot: string): Promise<MergedConfig> {
  // 1. Load .env
  loadDotenv({ path: join(projectRoot, ".env") });
  const apiKey = process.env.OP_API_KEY ?? "";
  if (!apiKey) {
    throw new Error("OP_API_KEY not set in .env");
  }
  storedApiKey = apiKey;

  // 2. Read forgeplan.config.json (required)
  const configPath = join(projectRoot, "forgeplan.config.json");
  let configRaw: string;
  try {
    configRaw = await readFile(configPath, "utf-8");
  } catch {
    throw new Error(
      `Missing forgeplan.config.json at ${configPath}. Run /forgeplan init to create it.`,
    );
  }
  const config: ForgeplanConfig = JSON.parse(configRaw);

  // 3. Read forgeplan.local.json (optional)
  let local: LocalConfig = {};
  const localPath = join(projectRoot, "forgeplan.local.json");
  try {
    const localRaw = await readFile(localPath, "utf-8");
    local = JSON.parse(localRaw);
  } catch {
    // Optional — warn but continue
  }

  // 4. Deep-merge local onto config
  const layers = { ...config.layers };
  if (local.layerOverrides) {
    for (const [name, overrides] of Object.entries(local.layerOverrides)) {
      if (layers[name]) {
        layers[name] = { ...layers[name], ...overrides };
      }
    }
  }

  // 5. Resolve tool paths
  const toolPaths: Record<string, string> = {};
  const configuredPaths = local.toolPaths ?? {};
  const toolNames = new Set<string>();

  // Gather tools from config
  for (const layer of Object.values(layers)) {
    const techTools = techStackTools(layer.techStack);
    for (const t of techTools) toolNames.add(t);
  }
  toolNames.add("git");
  toolNames.add("gh");
  toolNames.add("glab");

  for (const tool of toolNames) {
    if (configuredPaths[tool]) {
      toolPaths[tool] = configuredPaths[tool]!;
    } else {
      const result = await exec("which", [tool]);
      if (result.exitCode === 0 && result.stdout.trim()) {
        toolPaths[tool] = result.stdout.trim();
      }
    }
  }

  // 6. Derive git info per layer
  const gitInfo: Record<string, GitInfo> = {};
  for (const [name, layer] of Object.entries(layers)) {
    const cwd = layer.repoRoot ?? projectRoot;
    try {
      const [remoteResult, headResult] = await Promise.all([
        exec("git", ["remote", "get-url", "origin"], { cwd }),
        exec("git", ["symbolic-ref", "refs/remotes/origin/HEAD"], { cwd }),
      ]);

      const remoteUrl = remoteResult.stdout.trim();
      const baseBranch = headResult.stdout
        .trim()
        .replace("refs/remotes/origin/", "");

      gitInfo[name] = {
        repoSlug: extractRepoSlug(remoteUrl),
        hostType: detectHostType(remoteUrl),
        baseBranch: baseBranch || "main",
      };
    } catch {
      gitInfo[name] = {
        repoSlug: "",
        hostType: "other",
        baseBranch: "main",
      };
    }
  }

  // 7. Build merged config (no API key)
  const hookConventions: HookConventions = {
    manager: null,
    configFile: null,
    branchFormat: "{type}/WP-{id}-{slug}",
    commitSubjectMaxLength: 72,
    testParityRequired: false,
    testFilePattern: null,
    ...local.hookConventions,
  };

  return {
    openproject: config.openproject,
    layers,
    routing: config.routing,
    reviewers: config.reviewers ?? [],
    statuses: config.statuses,
    commitTrailer: config.commitTrailer ?? null,
    userId: local.userId ?? null,
    toolPaths,
    hookConventions,
    gitInfo,
  };
}

function techStackTools(techStack: string): string[] {
  switch (techStack.toLowerCase()) {
    case "dotnet":
    case ".net":
      return ["dotnet"];
    case "nextjs":
    case "react":
    case "vue":
    case "svelte":
    case "node":
      return ["node", "npm"];
    case "python":
    case "django":
    case "flask":
    case "fastapi":
      return ["python", "pip"];
    case "go":
      return ["go"];
    case "rust":
      return ["cargo"];
    case "java":
    case "spring":
      return ["java", "mvn"];
    default:
      return [];
  }
}

function extractRepoSlug(remoteUrl: string): string {
  // Handle both SSH and HTTPS URLs
  const match = remoteUrl.match(
    /(?:github\.com|gitlab\.com)[:/](.+?)(?:\.git)?$/,
  );
  return match?.[1] ?? remoteUrl;
}

function detectHostType(remoteUrl: string): "github" | "gitlab" | "other" {
  if (remoteUrl.includes("github.com")) return "github";
  if (remoteUrl.includes("gitlab.com") || remoteUrl.includes("gitlab"))
    return "gitlab";
  return "other";
}
