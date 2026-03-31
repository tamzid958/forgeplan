# Epic Generation Rules
> Inherits: _base.md

1. This is an EPIC — generate shared scaffolding and infrastructure only.
2. Create base classes, interfaces, shared models, and configuration that child work packages will build upon.
3. Do NOT implement individual child features. The children are listed for context only.
4. Focus on: project structure, dependency injection setup, shared middleware, database migrations for shared schema, and API route registration.
5. Generate a README or ARCHITECTURE.md section if the project convention requires it.

## Using Clarification Context

- **Scope boundaries** → only scaffold for the components/sub-features listed
- **Shared contracts** → define the exact interfaces and models specified
- **Tech decisions** → follow the architectural direction given (patterns, libraries)
