export interface OpenProjectConfig {
  url: string;
  projectId: string;
}

export interface LayerConfig {
  path: string;
  techStack: string;
  filePatterns: string[];
  buildCmd: string;
  testCmd?: string;
  lintFixCmd?: string;
  formatCmd?: string;
  repoRoot?: string;
}

export interface FallbackHeuristics {
  subjectTagPattern?: string;
  descriptionKeywords?: Record<string, string[]>;
}

export interface RoutingConfig {
  field: string;
  map: Record<string, string | string[]>;
  defaultLayer?: string;
  fallbackHeuristics?: FallbackHeuristics;
}

export interface StatusConfig {
  pickup_status: number | null;
  in_progress_status: number | null;
  success_status: number | null;
  partial_status: number | null;
  failure_status: number | null;
}

export interface HookConventions {
  manager?: string | null;
  configFile?: string | null;
  branchFormat?: string;
  commitSubjectMaxLength?: number;
  testParityRequired?: boolean;
  testFilePattern?: string | null;
}

export interface LocalConfig {
  toolPaths?: Record<string, string | null>;
  hookConventions?: HookConventions;
  layerOverrides?: Record<string, Partial<LayerConfig>>;
}

export interface GitInfo {
  repoSlug: string;
  hostType: "github" | "gitlab" | "other";
  baseBranch: string;
}

export interface ForgeplanConfig {
  openproject: OpenProjectConfig;
  layers: Record<string, LayerConfig>;
  routing: RoutingConfig;
  reviewers: string[];
  statuses: StatusConfig;
  commitTrailer?: string | null;
}

export interface MergedConfig {
  openproject: OpenProjectConfig;
  layers: Record<string, LayerConfig>;
  routing: RoutingConfig;
  reviewers: string[];
  statuses: StatusConfig;
  commitTrailer?: string | null;
  toolPaths: Record<string, string>;
  hookConventions: HookConventions;
  gitInfo: Record<string, GitInfo>;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}
