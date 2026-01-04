# Repo-Wide Agent Instructions

These instructions are automatically merged into every persona launched in this repository.
Edit this file to add project-specific context for your agents.

## Project Context
<!-- Describe your project so agents understand the codebase -->
This is [PROJECT NAME], a [brief description].

**Tech stack:**
- Language: [e.g., TypeScript, Python, Go]
- Framework: [e.g., React, FastAPI, Echo]
- Database: [e.g., PostgreSQL, SQLite, none]

**Key directories:**
- `src/` - Main source code
- `tests/` - Test files
- `docs/` - Documentation

## Conventions
<!-- Coding standards and patterns used in this project -->
- Use [style guide or formatter, e.g., Prettier, Black]
- Follow [naming convention, e.g., camelCase for functions]
- Write tests for new functionality
- Keep commits atomic and well-described

## Do Not
<!-- Things agents should avoid in this repo -->
- Modify files in `vendor/` or `node_modules/`
- Change configuration without discussing first
- Skip tests when making changes

## Notes
<!-- Any other context that helps agents work effectively -->
- The main branch is `main`, PRs required for all changes
- CI runs on every push; check status before marking done
