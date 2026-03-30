import { exec } from "../util/exec.js";
import type { GitInfo } from "../config/types.js";

export interface PROptions {
  title: string;
  body: string;
  baseBranch: string;
  reviewers?: string[];
  labels?: string[];
}

export async function createPR(
  cwd: string,
  gitInfo: GitInfo,
  options: PROptions,
): Promise<{ url: string; number: number }> {
  if (gitInfo.hostType === "gitlab") {
    return createGitLabMR(cwd, options);
  }
  return createGitHubPR(cwd, options);
}

async function createGitHubPR(
  cwd: string,
  options: PROptions,
): Promise<{ url: string; number: number }> {
  const args = [
    "pr",
    "create",
    "--title",
    options.title,
    "--body",
    options.body,
    "--base",
    options.baseBranch,
  ];

  if (options.reviewers?.length) {
    args.push("--reviewer", options.reviewers.join(","));
  }
  if (options.labels?.length) {
    args.push("--label", options.labels.join(","));
  }

  const result = await exec("gh", args, { cwd });
  if (result.exitCode !== 0) {
    throw new Error(`gh pr create failed: ${result.stderr}`);
  }

  const url = result.stdout.trim();
  const prNumber = parseInt(url.split("/").pop() ?? "0", 10);
  return { url, number: prNumber };
}

async function createGitLabMR(
  cwd: string,
  options: PROptions,
): Promise<{ url: string; number: number }> {
  const args = [
    "mr",
    "create",
    "--title",
    options.title,
    "--description",
    options.body,
    "--target-branch",
    options.baseBranch,
    "--yes",
  ];

  const result = await exec("glab", args, { cwd });
  if (result.exitCode !== 0) {
    throw new Error(`glab mr create failed: ${result.stderr}`);
  }

  const url = result.stdout.trim();
  const mrNumber = parseInt(url.split("/").pop() ?? "0", 10);
  return { url, number: mrNumber };
}

export async function closePR(
  cwd: string,
  gitInfo: GitInfo,
  prUrl: string,
): Promise<void> {
  if (gitInfo.hostType === "gitlab") {
    const result = await exec("glab", ["mr", "close", prUrl], { cwd });
    if (result.exitCode !== 0) {
      throw new Error(`glab mr close failed: ${result.stderr}`);
    }
  } else {
    const result = await exec("gh", ["pr", "close", prUrl], { cwd });
    if (result.exitCode !== 0) {
      throw new Error(`gh pr close failed: ${result.stderr}`);
    }
  }
}

export async function editPRBody(
  cwd: string,
  gitInfo: GitInfo,
  prUrl: string,
  body: string,
): Promise<void> {
  if (gitInfo.hostType === "gitlab") {
    const result = await exec(
      "glab",
      ["mr", "update", prUrl, "--description", body],
      { cwd },
    );
    if (result.exitCode !== 0) {
      throw new Error(`glab mr update failed: ${result.stderr}`);
    }
  } else {
    const result = await exec(
      "gh",
      ["pr", "edit", prUrl, "--body", body],
      { cwd },
    );
    if (result.exitCode !== 0) {
      throw new Error(`gh pr edit failed: ${result.stderr}`);
    }
  }
}
