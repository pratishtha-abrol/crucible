# Go tooling runs in containers so nothing needs installing on the host.
GO_IMAGE   ?= golang:1.23
LINT_IMAGE ?= golangci/golangci-lint:v1.64.8
MODEL_DIR  ?= $(CURDIR)/models
MODEL_FILE ?= qwen2.5-1.5b-instruct-q4_k_m.gguf
MODEL_URL  ?= https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/$(MODEL_FILE)
COMPOSE    := docker compose -f deploy/compose/docker-compose.yml

# Named volume caches modules + build artefacts between runs.
DOCKER_GO := docker run --rm -v $(CURDIR):/src -v crucible-gocache:/go -w /src

export MODEL_DIR MODEL_FILE

.PHONY: help dev down logs test build lint model

help: ## list targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-8s %s\n", $$1, $$2}'

dev: ## start the local stack (compose)
	$(COMPOSE) up -d

down: ## stop the local stack
	$(COMPOSE) down

logs: ## tail local stack logs
	$(COMPOSE) logs -f

test: ## unit tests
	$(DOCKER_GO) $(GO_IMAGE) go test ./...

build: ## compile all binaries
	$(DOCKER_GO) $(GO_IMAGE) go build -o bin/ ./cmd/...

lint: ## golangci-lint
	$(DOCKER_GO) $(LINT_IMAGE) golangci-lint run ./...

model: ## download the dev GGUF model into $(MODEL_DIR)
	@mkdir -p $(MODEL_DIR)
	curl -L --fail -C - -o $(MODEL_DIR)/$(MODEL_FILE) $(MODEL_URL)
