# Subtask Generation Rules

1. This is a SUBTASK — implement only the specific scope described. Do not implement the parent task or sibling subtasks.
2. The parent work package and siblings are listed in the hierarchy context. Use them to understand the broader context, but stay within this subtask's boundaries.
3. Follow existing patterns in the codebase. Match naming conventions, file organization, and architectural patterns.
4. Minimize scope — generate only what this subtask requires. If shared infrastructure is needed, check whether the parent or a sibling already provides it.
5. Place all generated files in the correct layer directory.
6. Only import existing dependencies. If a new dependency is absolutely required, note it clearly.
7. Write production-quality code with proper error handling and input validation.
8. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files scoped to this subtask.
