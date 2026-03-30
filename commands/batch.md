# Batch Process Work Packages

Process multiple WPs from comma-separated IDs in the arguments.

## Execution

1. Parse the comma-separated IDs: e.g., `16500,16501,16502`
2. For each WP ID, follow the full pipeline from `commands/wp.md`
3. Between each WP, for **each layer's repo root** (including separate repos):
   - Switch back to the base branch: `git checkout <base_branch>`
   - Ensure clean working tree: `git status --porcelain`
   - If there are leftover changes, stash them

## Tracking

Keep a running tally:
- Success count
- Partial count
- Failure count

## Summary

After all WPs are processed, print:
```
Batch complete: N success, N partial, N failed out of N total
```

List each WP with its result, layer(s), branch(es), and PR URL(s).
