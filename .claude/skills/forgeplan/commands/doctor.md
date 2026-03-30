# Health Check

Run diagnostic checks and report pass/warn/fail for each.

## Dependencies

Check each tool exists and report its version:

| Tool | Check | Required |
|------|-------|----------|
| curl | `curl --version` | Yes |
| jq | `jq --version` | Yes |
| git | `git --version` | Yes |
| gh | `gh --version` | No (needed for GitHub PRs) |
| glab | `glab --version` | No (needed for GitLab MRs) |

## Configuration

1. Check `.env` exists and contains `OP_API_KEY`
2. Check `forgeplan.config.json` exists and is valid JSON
3. Validate required fields: `openproject.url`, `openproject.projectId`, `layers` (at least one)
4. Check status mappings exist in `statuses` section
5. Count layers and list them

## OpenProject Connection

1. Test API connectivity:
```bash
curl -s -o /dev/null -w '%{http_code}' -u "apikey:${OP_API_KEY}" \
  -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3"
```
- 200 = pass
- 401 = fail (bad API key)
- 000 = fail (unreachable)

2. Verify project exists:
```bash
curl -s -o /dev/null -w '%{http_code}' -u "apikey:${OP_API_KEY}" \
  -H "Accept: application/hal+json" "${OP_BASE_URL}/api/v3/projects/${OP_PROJECT_ID}"
```

## Repository

For each layer:
1. Check the layer path exists
2. Check it's inside a git repo (`git -C <path> rev-parse`)
3. Check the remote exists
4. Check `CLAUDE.md` exists in the repo root
5. Check `.env` is in `.gitignore`

## Git Auth

Check if auth is available for PR creation:
- GitHub: `gh auth status`
- GitLab: `glab auth status`

## Summary

Print a table:
```
forgeplan doctor — N/N checks passed, N warning(s), N failure(s)
```
