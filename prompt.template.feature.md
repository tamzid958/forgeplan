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

1. This is a FEATURE — implement the complete feature as described.
2. Follow the existing architectural patterns for similar features in the codebase.
3. Include input validation, error handling, and edge case coverage.
4. If the feature requires API endpoints, follow the existing endpoint naming and response format conventions.
5. If the feature has a UI component, follow the existing component structure and styling patterns.
6. Place all generated files in the correct layer directory: ${LAYER_PATHS}.
7. Only import existing dependencies. If a new dependency is absolutely required, note it clearly.
8. If tests are part of the project convention (check CLAUDE.md), generate corresponding test files.
