# Breakdown Rules — Base
> Inherited by all type-specific writing files.

## Project Context Scan

Build a project snapshot before generating items. Every item must reference real layers, paths, and patterns.

### 1. `forgeplan.config.json` (source of truth)

Extract:
- `layers` — name, path, techStack, filePatterns, buildCmd per layer. Every item targets a named layer.
- `routing.map` — category-to-layer mapping. Sets `Category` on items.
- `routing.defaultLayer` — fallback layer.
- `routing.fallbackHeuristics.descriptionKeywords` — classify requirements when no category.
- `statuses.pickup_status` — default status for new items.

### 2. `forgeplan.local.json` (if available)

Extract:
- `layerOverrides.<name>.testCmd` — reference in acceptance criteria: "Tests pass: `<testCmd>`"
- `layerOverrides.<name>.lintFixCmd` / `formatCmd` — reference for code style items.
- `hookConventions.testParityRequired` — if true, add "test file created" to acceptance criteria.
- `hookConventions.testFilePattern` — exact pattern (e.g., `__tests__/{path}/{name}.test.{ext}`).

### 3. `CLAUDE.md` (per layer root)

Extract: tech stack versions, naming conventions, architectural patterns, error handling conventions.

### 4. Codebase scan per layer

```bash
find <layer.path> -maxdepth 3 -type f | head -80
```

Identify: API routes, models/schemas/migrations, UI components, shared types/DTOs, test structure.

### 5. Dependency manifests

Read `package.json` / `*.csproj` / `go.mod` / `Cargo.toml` / `pubspec.yaml` per layer. Never assume uninstalled dependencies.

### Snapshot usage

| Snapshot data | Used in |
|---------------|---------|
| Layer names + paths | Item `Category` and `Technical Context` |
| `techStack` per layer | Framework references in work details |
| Existing patterns | "Patterns to follow" guidance |
| `testCmd` + test patterns | Acceptance criteria |
| Installed deps | Scope feasibility checks |

## Decomposition Principles

1. **Ground in codebase** — reference real paths, patterns, module names. No abstract items.
2. **One developer, one item** — completable independently.
3. **Respect layer boundaries** — one layer per item. Cross-layer → separate items with `follows` dependency.
4. **Inherit conventions** — follow existing patterns, don't introduce new ones.
5. **Size**: Task 2-8h, SubTask 1-4h, Bug varies by defect scope.
6. **No invented requirements** — only decompose what exists in Epic + user answers. Flag ambiguity with `[ASSUMPTION]`.
7. **No duplicates** — skip if existing children cover the scope.

## Naming

| Type | Pattern | Example |
|------|---------|---------|
| Task | `[verb] [what] [where]` | `Add retry endpoint to verification API` |
| Story | `[user action]` | `Retry failed email verification` |
| SubTask | `[action] [target]` | `Update retry limit in AuthService` |
| Bug | `[symptom] [where]` | `Email link expires after 5min not 24h` |

Use real module names. Under 80 chars. No generic titles.

## Layer-Aware Decomposition

Every item must target a layer from config. Not optional.

1. Use `routing.map` to assign layers. Fallback: `descriptionKeywords` scoring.
2. Match requirements against `layers.<name>.path` and `filePatterns`.
3. Cross-layer deliverables → one item per layer, `follows` dependency from consumer to provider.
4. Use `techStack` value in work details (e.g., `nestjs` → "NestJS controller").
5. Use `buildCmd`/`testCmd` in acceptance criteria.

## Dependency Ordering

1. Schema / model / migration
2. Backend API / service
3. Frontend / UI
4. Integration / E2E / cross-cutting
5. Bugs — early if blocking

## Clarification Protocol

1. **Collect** questions from all type-specific rules against the Epic.
2. **Deduplicate** similar questions across types.
3. **Present once** as a numbered list grouped by priority.
4. **Apply answers** per each type's "Using Clarification Context" section.
5. **Tag assumptions** with `[ASSUMPTION]` if user says "proceed" without answering.

### Priority levels
1. **Blocking** — cannot generate items without this
2. **Quality** — items will be vague without this
3. **Refinement** — items work but could be better

## Quality Standards

Every description must be: **specific** (real files/modules), **testable** (pass/fail criteria), **scoped** (in/out stated), **actionable** (start immediately).
