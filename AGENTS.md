# AGENTS.md

## Workflow

Before every session:
1. Read `.agents/MEMORY.md`.
2. Read `docs/README.md` and the relevant module documentation.

Record durable cross-session project knowledge in `.agents/MEMORY.md`.

All project documentation must live under `docs/`. Use `docs/README.md` as the index and organize detailed documentation by module.

Feature:
1. Read docs.
2. Plan.
3. Write tests.
4. Implement.
5. Review tests.

Bug:
1. Find root cause.
2. Fix.
3. Verify.

Requirement changes must update:
- relevant documentation under `docs/`
- tests

## Commands

```sh
yarn install
yarn dev
yarn build
yarn type-check
```

Use Yarn only.

## Commit

Format: `<type>: <subject>`

Types: `feat`, `fix`, `chore`, `docs`, `style`, `refactor`, `build`, `revert`

## Rules

- No fallback code.
- No hidden errors.
- Fix root causes.
- Keep behavior explicit.
