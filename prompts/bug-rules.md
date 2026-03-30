# Bug Fix Generation Rules
> Inherits: _base.md

1. This is a BUG FIX — identify the root cause from the description and fix it.
2. Write a regression test that reproduces the bug before the fix and passes after.
3. Minimize changes — fix the specific issue without refactoring surrounding code.
4. If the root cause is unclear from the description, add a code comment explaining your diagnosis.
5. Check for similar patterns elsewhere in the codebase that might have the same bug.

## Using Clarification Context

- **Reproduction steps** → validate your fix covers the exact scenario
- **Error context** → match against stack traces to pinpoint the root cause
- **Environment details** → ensure the fix handles environment-specific conditions
