import { readFile, appendFile, mkdir } from "node:fs/promises";
import { join, dirname } from "node:path";

export interface RunLogEntry {
  wp_id: number;
  result: string;
  layers: Array<{
    name: string;
    branch: string;
    pr_url: string;
    result: string;
  }>;
  timestamp: string;
}

function logPath(logDir: string): string {
  return join(logDir, "logs", "run-summary.jsonl");
}

export async function appendRunLog(
  logDir: string,
  entry: RunLogEntry,
): Promise<void> {
  const filePath = logPath(logDir);
  await mkdir(dirname(filePath), { recursive: true });
  await appendFile(filePath, JSON.stringify(entry) + "\n", "utf-8");
}

export async function readRunLog(logDir: string): Promise<RunLogEntry[]> {
  const filePath = logPath(logDir);
  try {
    const content = await readFile(filePath, "utf-8");
    return content
      .split("\n")
      .filter((line) => line.trim() !== "")
      .map((line) => JSON.parse(line) as RunLogEntry);
  } catch {
    return [];
  }
}

export async function findRunByWpId(
  logDir: string,
  wpId: number,
): Promise<RunLogEntry | null> {
  const entries = await readRunLog(logDir);
  for (let i = entries.length - 1; i >= 0; i--) {
    if (entries[i].wp_id === wpId) {
      return entries[i];
    }
  }
  return null;
}
