# Project Setup

Set up forgeplan for this project interactively.

## Step 1: OpenProject Connection

Ask the user for:
1. **OpenProject URL** (e.g., `https://op.example.com`)
2. **OpenProject API key** — tell them: "Log in → Avatar → My account → Access tokens → Generate → API"
3. **Default project slug** (from the OpenProject URL)

Write `.env` with only the secret:
```
OP_API_KEY=<key>
```

## Step 2: Layer Paths

Ask: "Layer paths, comma-separated (e.g., `iam,eims-flutter` or `.` for current repo)"

For each path:
- Derive the layer name from `basename` of the path (`.` → `app`)
- Analyze the directory to detect `techStack`, `filePatterns`, and `buildCmd`
  - Look at package.json, *.csproj, pubspec.yaml, go.mod, Cargo.toml, etc.
  - Identify frameworks, languages, and build commands from what you find

## Step 3: Optional Settings

Ask for:
- **PR reviewers** — comma-separated usernames, or skip
- **Claude model** — alias like sonnet/opus/haiku (default: sonnet)
- **Validation command** — e.g., `npm run build`, or none

Append model and validation to `.env`:
```
CLAUDE_MODEL=<model>
VALIDATION_CMD=<cmd>
```

## Step 4: Build forgeplan.config.json

Assemble the config:
```json
{
  "openproject": {
    "url": "<url>",
    "projectId": "<slug>"
  },
  "layers": {
    "<name>": {
      "path": "<path>",
      "techStack": "<detected>",
      "filePatterns": ["<detected>"],
      "buildCmd": "<detected>"
    }
  },
  "routingField": "category",
  "routingMap": { "<name>": "<name>" },
  "defaultLayer": "<first layer>",
  "reviewers": ["<if provided>"],
  "hooks": {}
}
```

## Step 5: Per-Repo Setup

For each unique git repo found across the layers:

### CLAUDE.md
If missing, analyze the codebase and generate a `CLAUDE.md` with:
- Tech stack and framework versions
- Naming conventions observed
- File/folder structure patterns
- Build and test commands
- Architectural patterns (e.g., repository pattern, clean architecture)
- Error handling conventions

### .gitignore
Ensure `.env` and `logs/` are in `.gitignore`.

## Step 6: OpenProject Status Mapping

1. Test the connection:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3"
```

2. Fetch all statuses:
```bash
curl -s -u "apikey:${OP_API_KEY}" -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3/statuses"
```

3. Display the numbered status list to the user

4. Based on the status names, suggest mappings:
   - `pickup_status` — the "ready/todo" status
   - `in_progress_status` — the "in progress" status
   - `success_status` — the "in review" or "done" status
   - `partial_status` — the "in progress" status (or similar)
   - `failure_status` — 0 for no change, or a specific status

5. Ask the user to confirm or override each mapping

6. Merge the `statuses` section into `forgeplan.config.json`

## Done

Print a summary of everything created and next steps:
```
forgeplan doctor   # verify setup
forgeplan wp 123   # process a work package
```
