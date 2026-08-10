# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

CircleStory is a Phoenix 1.8 + LiveView web application backed by SQLite, with AI agent capabilities via Jido and Jido.AI. The runtime is managed by `mise` (Elixir 1.20.0-rc.3-otp-28, Erlang 28).

## Commands

```bash
# First-time setup
mix setup

# Start dev server
mix phx.server
# or with IEx
iex -S mix phx.server

# Run all tests
mix test

# Run a single test file
mix test test/path/to/my_test.exs

# Run only previously failed tests
mix test --failed

# Pre-commit check (compile with warnings-as-errors, remove unused deps, format, test)
mix precommit
```

**Always run `mix precommit` before finishing any task** to catch compile warnings, unused deps, formatting issues, and test failures in one pass.

## Architecture

```
lib/
  circle_story/          # Business logic (contexts, schemas)
    application.ex       # OTP supervision tree
    jido.ex              # Jido AI agent entry point (use Jido, otp_app: :circle_story)
    repo.ex              # Ecto.Repo backed by SQLite (ecto_sqlite3)
    mailer.ex            # Swoosh mailer
  circle_story_web/      # Phoenix web layer
    router.ex            # Routes (currently only GET / → PageController)
    endpoint.ex
    components/
      core_components.ex # Shared HEEx components (<.input>, <.icon>, etc.)
      layouts.ex         # App layout wrapping all LiveViews
    controllers/         # Traditional controllers (only PageController exists)
```

**Supervision tree** (application.ex): Telemetry → Repo → Ecto.Migrator → DNSCluster → PubSub → Endpoint → `CircleStory.Jido`

**Database**: SQLite via `ecto_sqlite3`. Migrations run automatically at startup in dev (skipped when `RELEASE_NAME` env var is set, for prod releases).

**AI agents**: `CircleStory.Jido` (`use Jido, otp_app: :circle_story`) is the application's Jido instance, started as an OTP child. Add new Jido actions/agents under `lib/circle_story/`.

**Assets**: Tailwind CSS v4 (no `tailwind.config.js`) + esbuild. Only `app.js` and `app.css` bundles are supported — import all vendor deps into these files.

## Key conventions

- All detailed Phoenix, Elixir, Ecto, LiveView, and HTML/CSS rules live in **AGENTS.md** — read it before writing any code.
- Use `Req` (`:req`) for HTTP — never `:httpoison`, `:tesla`, or `:httpc`.
- LiveView templates must begin with `<Layouts.app flash={@flash} ...>`.
- Use LiveView streams (`stream/3`, `stream_delete/3`) for all list/collection assigns.
- Dev dashboard at `/dev/dashboard`, mailbox preview at `/dev/mailbox`.
