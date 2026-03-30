# User Story Generation Rules

1. This is a USER STORY — implement the complete user-facing behavior as described.
2. Focus on the user's perspective: what the user sees, does, and experiences.
3. Follow the existing architectural patterns for similar features in the codebase.
4. Include input validation, error handling, and edge case coverage from the user's perspective.
5. If the story requires API endpoints, follow the existing endpoint naming and response format conventions.
6. If the story has a UI component, follow the existing component structure, styling patterns, and accessibility standards.
7. Place all generated files in the correct layer directory.
8. Only import existing dependencies. If a new dependency is absolutely required, note it clearly.
9. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files that validate the user-facing behavior.
