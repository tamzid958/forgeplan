import { existsSync } from "node:fs";
import type { MergedConfig, ValidationResult } from "./types.js";

export function validateConfig(config: MergedConfig): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  // OpenProject
  if (!config.openproject?.url) {
    errors.push("openproject.url is required");
  }
  if (!config.openproject?.projectId) {
    errors.push("openproject.projectId is required");
  }

  // Layers
  const layerNames = Object.keys(config.layers ?? {});
  if (layerNames.length === 0) {
    errors.push("At least one layer must be defined");
  }

  for (const [name, layer] of Object.entries(config.layers ?? {})) {
    if (!layer.path) {
      errors.push(`layers.${name}.path is required`);
    } else if (!existsSync(layer.path)) {
      errors.push(`layers.${name}.path does not exist: ${layer.path}`);
    }
    if (!layer.buildCmd) {
      errors.push(`layers.${name}.buildCmd is required`);
    }
  }

  // Routing
  const hasMap =
    config.routing?.map && Object.keys(config.routing.map).length > 0;
  const hasDefault = !!config.routing?.defaultLayer;
  if (!hasMap && !hasDefault) {
    errors.push(
      "routing.map must have entries OR routing.defaultLayer must be set",
    );
  }

  // Statuses
  if (!config.statuses?.in_progress_status) {
    errors.push("statuses.in_progress_status must be a non-zero integer");
  }
  if (!config.statuses?.success_status) {
    errors.push("statuses.success_status must be a non-zero integer");
  }
  if (!config.statuses?.partial_status) {
    warnings.push("statuses.partial_status is not set — PARTIAL results will not update status");
  }
  if (!config.statuses?.failure_status) {
    warnings.push("statuses.failure_status is not set — FAILURE results will not update status");
  }
  if (!config.statuses?.pickup_status) {
    warnings.push("statuses.pickup_status is not set — queue command will not work");
  }

  // Reviewers
  if (!config.reviewers || config.reviewers.length === 0) {
    warnings.push("No reviewers configured — PRs will be created without reviewers");
  }

  return {
    valid: errors.length === 0,
    errors,
    warnings,
  };
}
