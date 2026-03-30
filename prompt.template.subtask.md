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

1. This is a SUBTASK — implement only the specific scope described. Do not implement the parent task or sibling subtasks.
2. The parent work package and siblings are listed above in the Hierarchy section. Use them to understand the broader context, but stay within this subtask's boundaries.
3. Follow existing patterns in the codebase. Match naming conventions, file organization, and architectural patterns you observe.
4. Minimize scope — generate only what this subtask requires. If shared infrastructure is needed, check whether the parent task or a sibling already provides it.
5. Place all generated files in the correct layer directory: ${LAYER_PATHS}.
6. Only import existing dependencies. If a new dependency is absolutely required, note it clearly.
7. Write production-quality code with proper error handling and input validation.
8. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files scoped to this subtask.
