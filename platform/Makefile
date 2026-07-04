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

.PHONY: up
up: .env ## Start the platform (PROFILE=dev|google)
	$(COMPOSE) --profile $(PROFILE) up -d --build
	@echo "kiosk → https://kiosk.$$(grep -E '^PLATFORM_DOMAIN' .env | cut -d= -f2)"

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

.PHONY: smoke
smoke: ## Run the M1 done-when checks against a running platform
	./scripts/smoke-test.sh

.PHONY: check
check: ## Syntax-check the kiosk Python (no Docker needed)
	python3 -m compileall -q kiosk/app authstub && echo "python ok"
	@$(COMPOSE) config >/dev/null && echo "compose ok"
