SHELL := /bin/bash
SCRIPT := scripts/poc.sh

.PHONY: help up all test logs down clean kms-up kms-down
.DEFAULT_GOAL := help

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | \
	  awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Build + start the ssh-server container
	@bash $(SCRIPT) up

all: ## Run UC1-UC9 end to end (sets up CA + host cert first)
	@bash $(SCRIPT) all

test: ## Run the bats suite if available, else the scripted run
	@if command -v bats >/dev/null 2>&1; then bats test/uc.bats; else bash $(SCRIPT) all; fi

uc%: ## Run a single use case, e.g. `make uc5`
	@bash $(SCRIPT) $@

logs: ## Tail the ssh-server auth log
	@bash $(SCRIPT) logs

down: ## Stop + remove the container
	@bash $(SCRIPT) down

clean: ## down + delete the run/ working directory
	@bash $(SCRIPT) clean

kms-up: ## Start the optional Cosmian KMS + KRL distributor overlay
	@docker compose -f docker-compose.yml -f docker-compose.kms.yml up -d --build

kms-down: ## Stop the KMS overlay
	@docker compose -f docker-compose.yml -f docker-compose.kms.yml down -v
