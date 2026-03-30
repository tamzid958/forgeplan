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

1. This is a BUG FIX — identify the root cause from the description and fix it.
2. Write a regression test that reproduces the bug before the fix and passes after.
3. Minimize changes — fix the specific issue without refactoring surrounding code.
4. If the root cause is unclear from the description, add a code comment explaining your diagnosis.
5. Check for similar patterns elsewhere in the codebase that might have the same bug.
6. Place all generated files in the correct layer directory: ${LAYER_PATHS}.
7. Only import existing dependencies.
8. Write production-quality code with proper error handling.
