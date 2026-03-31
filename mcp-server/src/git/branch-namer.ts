import type { HookConventions } from "../config/types.js";

export interface BranchInfo {
  branchName: string;
  branchType: string;
  baseBranch: string;
}

const WP_TYPE_TO_BRANCH: Record<string, string> = {
  bug: "bug",
  feature: "feature",
  epic: "feature",
  "user story": "feature",
  task: "task",
  subtask: "subtask",
};

const MAX_BRANCH_LENGTH = 80;

export function deriveBranchName(
  wpId: number,
  wpType: string,
  subject: string,
  hookConventions: HookConventions,
  baseBranch: string,
): BranchInfo {
  const branchType =
    WP_TYPE_TO_BRANCH[wpType.toLowerCase()] ?? "task";

  const slug = subject
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");

  const format = hookConventions.branchFormat ?? "{type}/WP-{id}-{slug}";

  // Build the branch without slug to calculate available space
  const withoutSlug = format
    .replace("{type}", branchType)
    .replace("{id}", String(wpId))
    .replace("{slug}", "");

  const availableLength = MAX_BRANCH_LENGTH - withoutSlug.length;
  const truncatedSlug =
    slug.length > availableLength
      ? slug.substring(0, availableLength).replace(/-$/, "")
      : slug;

  const branchName = format
    .replace("{type}", branchType)
    .replace("{id}", String(wpId))
    .replace("{slug}", truncatedSlug);

  return { branchName, branchType, baseBranch };
}
