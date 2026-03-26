# primer -- Portable AI Infrastructure Config

One canonical `.ai/` directory generates CLAUDE.md, AGENTS.md, .cursorrules, and .hermes.md. Stop copy-pasting between tools.

## Why

- Your project has constraints, gotchas, and build commands that LLMs need to follow
- That knowledge lives in CLAUDE.md -- but Codex reads AGENTS.md, Cursor reads .cursorrules
- When constraints change, you update one file and forget the others
- primer stores everything in `.ai/project.yaml` and generates all tool-native configs from it

## Install

```bash
# Clone and symlink
git clone git@github.com:zerone0x/primer.git ~/.primer
ln -sf ~/.primer/bin/primer /usr/local/bin/primer

# Verify
primer --version
```

Requirements: `bash 4+`, `jq`. Optional: `yq` (for full YAML support, falls back to regex parsing).

```bash
# macOS
brew install jq        # required
brew install yq        # optional, recommended
```

## Quick Start

```bash
# In your project directory
primer init --template rust-cli
# Auto-detects stack from Cargo.toml, package.json, go.mod, pyproject.toml, etc.
primer init

# Generate all tool-native configs
primer emit --all
# Or target one
primer emit claude-md

# Add a gotcha to the knowledge store
primer kpl add gotcha no-orm-caching \
  "Never cache ORM queries -- cache at the service layer" \
  "src/db/**,lib/cache.ts" high

# Sync to all detected tools at once
primer seams sync
```

## Two-Layer Architecture

primer walks from `$PWD` up to `$HOME`, collecting every `.ai/` directory it finds. Deeper directories override shallower ones.

### Layer 1: Global Base (`~/.ai/`)

Set up once with `primer init` (global mode). Provides defaults that no single project should have to define:

- **Trust policy** -- which agents can modify what (Claude Code can auto-apply gotchas; only humans touch constraints)
- **Build patterns** -- `cargo test`, `go test ./...`, `pytest` by stack, auto-detected
- **Quality gates** -- common lint/fmt/test thresholds
- **Git conventions** -- commit message format, branch naming

```
~/.ai/
  trust-policy.yaml     # per-agent write permissions
  defaults/
    build-patterns.toml  # test/lint/build/fmt per stack
    git-conventions.toml
    quality-gates.toml
```

### Layer 2: Project-Specific (`.ai/`)

Created by `primer init`. Contains everything specific to your project:

```
.ai/
  project.yaml           # canonical config (name, phase, constraints, build, stack)
  knowledge/
    gotchas.toml          # non-inferable gotchas scoped to file globs
    constraints.toml      # hard rules AI must follow
    failures.toml         # past mistakes to avoid
    manifest.toml         # entry index + token budgets
    decisions/            # ADR-style decision records (Markdown)
  phases/
    bootstrap.yaml        # guidance for early project phase
    growth.yaml           # guidance for growth phase
  evolution/
    proposals/            # pending changes from any agent
    applied/              # processed proposals
    log.jsonl             # full audit trail
  plugins/
    generators/           # custom emit targets
    hooks/                # lifecycle hooks (pre-emit, post-evolve, etc.)
    commands/             # custom primer subcommands
    validators/           # custom validation rules
  mcp-servers.yaml        # MCP server definitions -> .mcp.json
```

## Commands

| Command | Description |
|---|---|
| `primer init [--template NAME]` | Create `.ai/` from template (auto-detects stack if no template given) |
| `primer emit <target\|--all>` | Generate tool-native config (claude-md, agents-md, cursorrules, hermes-md) |
| `primer validate` | Validate project.yaml and run validator plugins |
| `primer budget` | Show total byte usage across all `.ai/` sources |
| `primer kpl <sub>` | Knowledge persistence: `init`, `add`, `query`, `prune`, `budget` |
| `primer evolve [--auto]` | Process evolution proposals (interactive or auto-apply) |
| `primer log [--agent X] [--since DATE]` | Query the evolution audit log |
| `primer hooks <sub>` | Hook management: `list`, `run`, `install`, `test` |
| `primer seams <sub>` | Seam sync: `sync`, `detect`, `status`, `diff` |
| `primer mcp <sub>` | MCP servers: `list`, `sync`, `add` |

## Cross-Agent Evolution

Any agent can propose a change. No agent can silently modify constraints.

```
# Agent writes a proposal
.ai/evolution/proposals/20260326-claude-code-gotcha.json
{
  "type": "gotcha",
  "agent": "claude-code",
  "change": { "id": "no-unwrap", "summary": "Use expect() not unwrap()" }
}

# Human (or --auto mode) reviews
primer evolve

# Applied proposals move to .ai/evolution/applied/
# Every action is logged to .ai/evolution/log.jsonl
```

Trust policy controls what each agent can do:

```yaml
# ~/.ai/trust-policy.yaml
trust_levels:
  claude-code:
    can_modify: [gotchas, skills, knowledge, build]
    cannot_modify: [constraints, trust-policy]
    max_confidence_auto_apply: 0.9
  codex:
    can_modify: [gotchas, skills]
    cannot_modify: [constraints, trust-policy, knowledge]
  cursor:
    can_modify: [gotchas]
```

Conflict resolution is per-section: `highest_confidence`, `human_review`, `auto_merge`, or `latest_wins`.

## Templates

| Template | Stack |
|---|---|
| `rust-cli` | Rust / clap |
| `nextjs-app` | TypeScript / Next.js |
| `go-service` | Go |
| `python-api` | Python / FastAPI |
| `typescript-lib` | TypeScript |
| `global-base` | Layer 1 defaults (trust policy, build patterns) |

Each template ships with stack-specific constraints, gotchas, phase guidance, and build commands.

```bash
primer init --list  # see all templates
```

## Progressive Disclosure (KPL Token Budget)

The Knowledge Persistence Layer controls how much context gets injected, in three tiers:

| Tier | What | Default budget |
|---|---|---|
| Tier 0 (always) | Project name, entry count | 200 tokens |
| Tier 1 (scope-match) | Gotchas/constraints matching current file globs | 1,500 tokens |
| Tier 2 (on-demand) | Full ADR decision records | 5,000 tokens |

```bash
primer kpl budget  # show current usage per tier
```

Knowledge entries are scoped to file globs so only relevant context loads:

```toml
# .ai/knowledge/gotchas.toml
[no-orm-caching]
summary = "Never cache ORM queries -- cache at the service layer"
applies_to = ["src/db/**", "lib/cache.ts"]
severity = "high"
```

## Hooks

Hooks are executable scripts organized by lifecycle stage, chained via stdin/stdout:

```
pre-generate  post-generate  pre-emit  post-emit
pre-evolve    post-evolve    on-knowledge-update
on-phase-change  on-skill-create  on-error
```

```bash
primer hooks install ./my-hook.sh pre-emit 10
primer hooks list
primer hooks test pre-emit
```

Hooks are sorted by numeric prefix (`10-validate.sh` runs before `20-lint.sh`).

## MCP Server Management

Define MCP servers in `.ai/mcp-servers.yaml`, sync to `.mcp.json`:

```bash
primer mcp add my-server npx '"-y" "@my/mcp-server"'
primer mcp sync   # writes .mcp.json for Claude Code
primer mcp list
```

## Requirements

- bash 4+
- jq (required for MCP sync, knowledge management, evolution)
- yq (optional -- enables full YAML parsing; primer falls back to grep/sed without it)

## License

MIT
