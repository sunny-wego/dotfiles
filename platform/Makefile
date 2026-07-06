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

.PHONY: parity
parity: ## Coolify parity gate — validate the client against the live Coolify
	./coolify/parity-gate.sh

.PHONY: bootstrap
bootstrap: ## Self-host the control plane on Coolify (kiosk as a Coolify service)
	./coolify/bootstrap.sh

# ── Local parity on macOS/Colima (real Coolify + real oauth2-proxy + mock OIDC) ─
.PHONY: local-up
local-up: ## Start the local Colima parity stack (see local/README.md)
	./local/up.sh

.PHONY: local-certs
local-certs: ## Mint a browser-trusted wildcard cert for the local domain (mkcert)
	./local/mkcert.sh

.PHONY: parity-local
parity-local: ## Run the parity gate against the local Colima Coolify
	./local/parity-local.sh

.PHONY: local-down
local-down: ## Stop the local parity stack (keep volumes)
	$(COMPOSE) --env-file .env --env-file local/.env.local \
	  -f docker-compose.yml -f local/docker-compose.local.yml \
	  --profile local down

.PHONY: check
check: ## Syntax-check the kiosk Python (no Docker needed)
	python3 -m compileall -q kiosk/app authstub && echo "python ok"
	@$(COMPOSE) config >/dev/null && echo "compose ok"

.PHONY: test
test: ## Run the fast unit tests — behavior/contract, no Docker/Postgres
	python3 -m pytest kiosk/tests -q
