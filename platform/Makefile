# Internal App Platform — M1 walking skeleton.
# One box, one command. See M1.md for the full runbook.

SHELL := /usr/bin/env bash
COMPOSE := docker compose
# Auth profile: `dev` (stub, default) or `google` (oauth2-proxy).
PROFILE ?= dev

.PHONY: help
help: ## Show targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}'

.env: ## Create .env from the example (edit before `make up`)
	@test -f .env || cp .env.example .env
	@echo "wrote .env — review OPENROUTER_API_KEY / AUTH_MODE before 'make up'"

.PHONY: build
build: ## Build the kiosk image
	$(COMPOSE) build kiosk

.PHONY: preflight
preflight: ## Check the box is ready before `make up` (Docker, ports, .env, disk, keys)
	@./scripts/preflight.sh

.PHONY: up
up: .env preflight ## Start the shared services (PROFILE=dev|google); Coolify is the engine
	$(COMPOSE) --profile $(PROFILE) up -d --build
	@echo "shared services up. Ingress + deploys are Coolify's — see coolify/README.md"

.PHONY: down
down: ## Stop the platform (keep volumes)
	$(COMPOSE) --profile dev --profile google down

.PHONY: clean
clean: ## Stop and remove volumes (DESTRUCTIVE)
	$(COMPOSE) --profile dev --profile google down -v

.PHONY: logs
logs: ## Tail kiosk logs
	$(COMPOSE) logs -f kiosk

.PHONY: samples
samples: ## Zip the Node + Python sample apps into ./dist
	./scripts/make-samples.sh

.PHONY: check
check: ## Syntax-check the kiosk Python (no Docker needed)
	python3 -m compileall -q kiosk/app authstub && echo "python ok"
	@$(COMPOSE) config >/dev/null && echo "compose ok"

.PHONY: test
test: ## Run the fast unit tests — behavior/contract, no Docker/Postgres
	python3 -m pytest kiosk/tests -q
