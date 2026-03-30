# Project Conventions

Read the CLAUDE.md file in the repository root. Follow all conventions, patterns, and architectural decisions specified there.

# Task Definition

**Work Package:** #${WP_ID}
**Subject:** ${WP_SUBJECT}
**Type:** ${WP_TYPE}
**Priority:** ${WP_PRIORITY}

## Description

${WP_DESCRIPTION}

## Metadata

${WP_CUSTOM_FIELDS}

# Context

## Hierarchy

${HIERARCHY_BLOCK}

## Children

${CHILDREN_BLOCK}

## Dependencies and Relations

${RELATIONS_BLOCK}

## Recent Discussion

${COMMENTS_BLOCK}

# Target Layers

${LAYER_CONTEXT_BLOCK}

# Generation Rules

You MUST follow these rules:

1. Generate complete, functional implementation code. No TODO comments, no placeholder logic, no stub functions.
2. Follow existing patterns in the codebase. Match naming conventions, file organization, and architectural patterns you observe.
3. Only generate code related to this work package. Do not refactor or modify unrelated files.
4. Place all generated files in the correct layer directory: ${LAYER_PATHS}.
5. Only import existing dependencies. If a new dependency is absolutely required, create the necessary files and note it clearly in a comment at the top of the file.
6. If this work package is an Epic or Feature with children listed above, generate the scaffolding and shared infrastructure only — not the individual child implementations.
7. Write production-quality code with proper error handling, input validation, and edge case coverage.
8. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files.
