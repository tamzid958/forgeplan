import { exec } from "../util/exec.js";

export interface GitStatusResult {
  clean: boolean;
  porcelain: string;
  branch: string;
}

export async function gitStatus(cwd: string): Promise<GitStatusResult> {
  const [statusResult, branchResult] = await Promise.all([
    exec("git", ["status", "--porcelain"], { cwd }),
    exec("git", ["branch", "--show-current"], { cwd }),
  ]);

  return {
    clean: statusResult.stdout.trim() === "",
    porcelain: statusResult.stdout,
    branch: branchResult.stdout.trim(),
  };
}

export async function gitFetch(cwd: string): Promise<void> {
  const result = await exec("git", ["fetch", "origin"], { cwd });
  if (result.exitCode !== 0) {
    throw new Error(`git fetch failed: ${result.stderr}`);
  }
}

export async function gitBaseBranch(cwd: string): Promise<string> {
  const result = await exec(
    "git",
    ["symbolic-ref", "refs/remotes/origin/HEAD"],
    { cwd },
  );
  if (result.exitCode !== 0) {
    return "main";
  }
  return result.stdout.trim().replace("refs/remotes/origin/", "");
}

export async function gitPrepareBranch(
  cwd: string,
  branchName: string,
  baseBranch: string,
): Promise<{ status: "created" | "resumed_local" | "resumed_remote" }> {
  // Check local
  const localCheck = await exec(
    "git",
    ["branch", "--list", branchName],
    { cwd },
  );
  if (localCheck.stdout.trim()) {
    await exec("git", ["checkout", branchName], { cwd });
    return { status: "resumed_local" };
  }

  // Check remote
  const remoteCheck = await exec(
    "git",
    ["branch", "-r", "--list", `origin/${branchName}`],
    { cwd },
  );
  if (remoteCheck.stdout.trim()) {
    await exec(
      "git",
      ["checkout", "-b", branchName, `origin/${branchName}`],
      { cwd },
    );
    return { status: "resumed_remote" };
  }

  // Create new
  const result = await exec(
    "git",
    ["checkout", "-b", branchName, `origin/${baseBranch}`],
    { cwd },
  );
  if (result.exitCode !== 0) {
    throw new Error(`Failed to create branch: ${result.stderr}`);
  }
  return { status: "created" };
}

export async function gitStageAll(cwd: string): Promise<void> {
  await exec("git", ["add", "-A"], { cwd });
}

export async function gitCommit(
  cwd: string,
  message: string,
): Promise<{ sha: string }> {
  const result = await exec("git", ["commit", "-m", message], { cwd });
  if (result.exitCode !== 0) {
    throw new Error(`Commit failed: ${result.stderr}\n${result.stdout}`);
  }

  const shaResult = await exec("git", ["rev-parse", "HEAD"], { cwd });
  return { sha: shaResult.stdout.trim() };
}

export async function gitPush(
  cwd: string,
  branchName: string,
): Promise<{ success: boolean; error?: string }> {
  const result = await exec(
    "git",
    ["push", "-u", "origin", branchName],
    { cwd },
  );
  if (result.exitCode !== 0) {
    return { success: false, error: result.stderr };
  }
  return { success: true };
}

export async function gitDiffNames(
  cwd: string,
  baseBranch: string,
): Promise<string[]> {
  const result = await exec(
    "git",
    ["diff", "--name-only", `origin/${baseBranch}...HEAD`],
    { cwd },
  );
  return result.stdout
    .trim()
    .split("\n")
    .filter((f) => f.length > 0);
}

export async function gitBranchExists(
  cwd: string,
  wpId: number,
): Promise<{ local?: string; remote?: string }> {
  const pattern = `*WP-${wpId}*`;

  const [localResult, remoteResult] = await Promise.all([
    exec("git", ["branch", "--list", pattern], { cwd }),
    exec("git", ["branch", "-r", "--list", `origin/${pattern}`], { cwd }),
  ]);

  const local = localResult.stdout.trim().replace(/^\*?\s*/, "") || undefined;
  const remote =
    remoteResult.stdout
      .trim()
      .replace(/^\s*origin\//, "")
      || undefined;

  return { local, remote };
}

export async function gitDeleteBranch(
  cwd: string,
  branchName: string,
  remote?: boolean,
): Promise<void> {
  await exec("git", ["branch", "-D", branchName], { cwd });
  if (remote) {
    await exec("git", ["push", "origin", "--delete", branchName], { cwd });
  }
}
