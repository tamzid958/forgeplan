# Epic Generation Rules

1. This is an EPIC — generate shared scaffolding and infrastructure only.
2. Create base classes, interfaces, shared models, and configuration that child work packages will build upon.
3. Do NOT implement individual child features. The children are listed for context only.
4. Focus on: project structure, dependency injection setup, shared middleware, database migrations for shared schema, and API route registration.
5. Generate a README or ARCHITECTURE.md section if the project convention requires it.
6. Place all generated files in the correct layer directory.
7. Only import existing dependencies. If a new dependency is absolutely required, note it clearly.
8. Write production-quality code with proper error handling.
