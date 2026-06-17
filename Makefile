SHELL := /usr/bin/env bash

.DEFAULT_GOAL := help

ifneq ("$(wildcard .env)","")
include .env
export
endif

.PHONY: help bootstrap branch render-workflow install run check-env

help:
	@echo "Available targets:"
	@echo "  make bootstrap        Create/switch to the branch from NAME and render the workflow"
	@echo "  make branch           Create/switch to the branch from NAME"
	@echo "  make render-workflow  Generate workflows/weather_pipeline.yaml from .env"
	@echo "  make install          Install Python dependencies with uv"
	@echo "  make run              Run the local ingestion script"

check-env:
	@test -f .env || { echo "Missing .env. Run: cp .env.example .env"; exit 1; }
	@test -n "$(NAME)" || { echo "Missing NAME in .env"; exit 1; }
	@test "$(NAME)" != "your-name" || { echo "Update NAME in .env before running make"; exit 1; }
	@[[ "$(NAME)" =~ ^[a-z0-9][a-z0-9_-]*$$ ]] || { echo "Invalid NAME='$(NAME)'. Use lowercase letters, digits, _ or -."; exit 1; }
	@current_branch="$$(git branch --show-current)"; \
	if git show-ref --verify --quiet "refs/heads/$(NAME)" && [[ "$$current_branch" != "$(NAME)" ]]; then \
		echo "NAME='$(NAME)' is already used by an existing local branch."; \
		echo "Choose another NAME in .env, or switch to that branch first: git switch $(NAME)"; \
		exit 1; \
	fi; \
	if git show-ref --verify --quiet "refs/remotes/origin/$(NAME)" && [[ "$$current_branch" != "$(NAME)" ]]; then \
		echo "NAME='$(NAME)' is already used by an existing remote branch origin/$(NAME)."; \
		echo "Choose another NAME in .env, or check out that branch first: git switch --track origin/$(NAME)"; \
		exit 1; \
	fi

branch: check-env
	@current_branch="$$(git branch --show-current)"; \
	if [[ "$$current_branch" == "$(NAME)" ]]; then \
		echo "Already on branch $(NAME)"; \
	else \
		echo "Creating branch $(NAME)"; \
		git switch -c "$(NAME)"; \
	fi

render-workflow: check-env
	@bash scripts/render-workflow.sh

bootstrap: branch render-workflow
	@echo "Bootstrap complete for $(NAME)"

install:
	@uv sync

run: check-env
	@PROJECT_ID="$(PROJECT_ID)" \
	BQ_DATASET="$(BQ_BRONZE_DATASET)" \
	BQ_TABLE="$(BQ_STATIONS_WEATHER_RAW_TABLE)" \
	uv run python -m app.main
