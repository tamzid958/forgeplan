# Generation Rules — Base
> Shared rules for all WP types. Each type-specific file inherits these.

1. Place all generated files in the correct layer directory.
2. Only import existing dependencies. If a new dependency is absolutely required, note it clearly in a comment.
3. Write production-quality code with proper error handling, input validation, and edge case coverage.
4. Follow existing patterns in the codebase. Match naming conventions, file organization, and architectural patterns you observe.
5. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files.
6. Do not refactor or modify unrelated files.

## Using Clarification Context

If the user provided answers during the quality gate (Step 5), use them to inform your implementation:
- **Assumptions** logged during Step 5d → honor them, note any you override with a code comment
