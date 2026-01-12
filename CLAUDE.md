# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Zrpc is an Elixir OTP application (requires Elixir ~> 1.19). The project uses a supervised application structure with `Zrpc.Application` as the entry point.

## Common Commands

```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run all tests
mix test

# Run a specific test file
mix test test/zrpc_test.exs

# Run a specific test by line number
mix test test/zrpc_test.exs:5

# Format code
mix format

# Check formatting without changes
mix format --check-formatted

# Run Credo static analysis
mix credo

# Run Credo in strict mode
mix credo --strict

# Run Dialyzer type checking
mix dialyzer

# Start interactive shell with project loaded
iex -S mix
```

## Architecture

- `lib/zrpc.ex` - Main module
- `lib/zrpc/application.ex` - OTP Application supervisor (entry point defined in mix.exs)
