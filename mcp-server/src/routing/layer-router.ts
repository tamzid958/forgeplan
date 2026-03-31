import type { MergedConfig, LayerConfig } from "../config/types.js";
import type { WorkPackage } from "../openproject/types.js";

export interface RoutingResult {
  layers: Array<{ name: string; config: LayerConfig }>;
  method: string;
  needsConfirmation: boolean;
  warnings: string[];
}

export function routeWP(config: MergedConfig, wp: WorkPackage): RoutingResult {
  const routing = config.routing;
  const fieldName = routing.field ?? "category";
  const warnings: string[] = [];

  // Get field value from WP
  const fieldValue = getFieldValue(wp, fieldName);

  // Strategy 1: Direct map lookup
  if (fieldValue) {
    const mapped = routing.map[fieldValue];
    if (mapped) {
      const layerNames = Array.isArray(mapped) ? mapped : [mapped];
      const layers = resolveLayerNames(config, layerNames, warnings);
      if (layers.length > 0) {
        return {
          layers,
          method: `${fieldName} → routing.map["${fieldValue}"]`,
          needsConfirmation: false,
          warnings,
        };
      }
    }
  }

  // Strategy 2: Subject tag pattern
  if (routing.fallbackHeuristics?.subjectTagPattern) {
    const pattern = new RegExp(routing.fallbackHeuristics.subjectTagPattern);
    const match = wp.subject.match(pattern);
    if (match?.[1]) {
      const tag = match[1];
      // Try matching tag against map keys (case-insensitive)
      for (const [key, value] of Object.entries(routing.map)) {
        if (key.toLowerCase() === tag.toLowerCase()) {
          const layerNames = Array.isArray(value) ? value : [value];
          const layers = resolveLayerNames(config, layerNames, warnings);
          if (layers.length > 0) {
            return {
              layers,
              method: `subject tag [${tag}] → routing.map["${key}"]`,
              needsConfirmation: false,
              warnings,
            };
          }
        }
      }
    }
  }

  // Strategy 3: Description keyword scoring
  if (routing.fallbackHeuristics?.descriptionKeywords) {
    const desc = (wp.description?.raw ?? "").toLowerCase();
    const scores: Record<string, number> = {};

    for (const [layerName, keywords] of Object.entries(
      routing.fallbackHeuristics.descriptionKeywords,
    )) {
      let score = 0;
      for (const kw of keywords) {
        if (desc.includes(kw.toLowerCase())) {
          score++;
        }
      }
      if (score > 0) {
        scores[layerName] = score;
      }
    }

    const scoredLayers = Object.entries(scores)
      .sort(([, a], [, b]) => b - a)
      .map(([name]) => name);

    if (scoredLayers.length > 0) {
      const layers = resolveLayerNames(config, scoredLayers, warnings);
      if (layers.length > 0) {
        return {
          layers,
          method: `description keywords (${scoredLayers.map((n) => `${n}:${scores[n]}`).join(", ")})`,
          needsConfirmation: false,
          warnings,
        };
      }
    }
  }

  // Strategy 4: Default layer with confirmation
  if (routing.defaultLayer) {
    const layers = resolveLayerNames(config, [routing.defaultLayer], warnings);
    if (layers.length > 0) {
      warnings.push(
        `No routing match found. Falling back to default layer: ${routing.defaultLayer}`,
      );
      return {
        layers,
        method: `defaultLayer (${routing.defaultLayer})`,
        needsConfirmation: true,
        warnings,
      };
    }
  }

  // No routing possible
  return {
    layers: [],
    method: "none",
    needsConfirmation: false,
    warnings: [
      "No routing match found and no defaultLayer configured. Cannot determine target layer.",
    ],
  };
}

function getFieldValue(wp: WorkPackage, fieldName: string): string | null {
  switch (fieldName) {
    case "category":
      return wp._links?.category?.title ?? null;
    case "type":
      return wp._links?.type?.title ?? null;
    case "priority":
      return wp._links?.priority?.title ?? null;
    default:
      return wp._links?.category?.title ?? null;
  }
}

function resolveLayerNames(
  config: MergedConfig,
  names: string[],
  warnings: string[],
): Array<{ name: string; config: LayerConfig }> {
  const result: Array<{ name: string; config: LayerConfig }> = [];
  for (const name of names) {
    const layerConfig = config.layers[name];
    if (layerConfig) {
      result.push({ name, config: layerConfig });
    } else {
      warnings.push(`Layer "${name}" referenced in routing but not defined in config`);
    }
  }
  return result;
}
