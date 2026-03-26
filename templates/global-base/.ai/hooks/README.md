# Hooks

Hooks are executable scripts that run at lifecycle stages (pre-emit, post-emit, pre-evolve, etc.).

## Organization

Place hooks in subdirectories named after the stage they target:

```
hooks/
  pre-emit/
    10-validate.sh
    20-lint.sh
  post-emit/
    10-format.sh
  pre-evolve/
    10-trust-check.sh
```

## Naming

Prefix with a two-digit number to control execution order. Hooks chain via stdin/stdout -- the output of one becomes the input of the next.

## Scope

- **~/.ai/hooks/** — Global hooks, run for every project.
- **<project>/.ai/hooks/** — Project-specific hooks, run only in that project.

Project hooks execute before global hooks (deepest-first discovery in `paic_discover_sources`).
