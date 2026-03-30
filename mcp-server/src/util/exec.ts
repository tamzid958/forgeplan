import { execFile as nodeExecFile } from "node:child_process";

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export interface ExecOptions {
  cwd?: string;
  timeout?: number;
  env?: Record<string, string | undefined>;
}

const DEFAULT_TIMEOUT = 120_000;

export function exec(
  cmd: string,
  args: string[],
  options?: ExecOptions,
): Promise<ExecResult> {
  return new Promise((resolve) => {
    const child = nodeExecFile(
      cmd,
      args,
      {
        cwd: options?.cwd,
        timeout: options?.timeout ?? DEFAULT_TIMEOUT,
        env: options?.env
          ? { ...process.env, ...options.env }
          : undefined,
        maxBuffer: 10 * 1024 * 1024,
      },
      (error, stdout, stderr) => {
        if (error && "killed" in error && error.killed) {
          resolve({
            stdout: stdout ?? "",
            stderr: `Process timed out after ${options?.timeout ?? DEFAULT_TIMEOUT}ms`,
            exitCode: 124,
          });
          return;
        }

        resolve({
          stdout: stdout ?? "",
          stderr: stderr ?? "",
          exitCode: error ? (error as NodeJS.ErrnoException & { code?: number }).code === undefined
            ? 1
            : typeof error.code === "number"
              ? error.code
              : 1
            : 0,
        });
      },
    );

    // Safety: kill on timeout if node doesn't handle it
    const timeoutMs = options?.timeout ?? DEFAULT_TIMEOUT;
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
    }, timeoutMs + 1000);

    child.on("close", () => clearTimeout(timer));
  });
}
