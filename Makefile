# Convenience wrappers around docker compose and the backup scripts.
# Run `make help` to list targets.

.DEFAULT_GOAL := help
COMPOSE := docker compose

.PHONY: help up down stop start restart ps logs config pull upgrade prune \
        backup backup-db backup-data restore-db restore-data claim

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

up: ## Start all services in the background
	$(COMPOSE) up -d

down: ## Stop and remove all containers (volumes preserved)
	$(COMPOSE) down

stop: ## Stop services without removing containers
	$(COMPOSE) stop

start: ## Start previously-stopped services
	$(COMPOSE) start

restart: ## Restart all services
	$(COMPOSE) restart

ps: ## Show service status
	$(COMPOSE) ps

logs: ## Follow logs (use S=paperclip to scope to one service)
	$(COMPOSE) logs -f $(S)

config: ## Validate and render the merged compose config
	$(COMPOSE) config

pull: ## Pull the pinned images
	$(COMPOSE) pull

upgrade: pull ## Pull images and recreate containers (after bumping the image sha)
	$(COMPOSE) up -d --remove-orphans
	@echo "Upgrade applied. Run 'make prune' to remove old images once healthy."

prune: ## Remove dangling images left behind by an upgrade
	docker image prune -f

claim: ## Print the one-time board-claim URL from the logs (first run)
	@$(COMPOSE) logs paperclip | grep -i 'board-claim' || \
		echo "No claim URL found yet. Wait for startup, then re-run 'make claim'."

backup: backup-db backup-data ## Back up the database and the data volume

backup-db: ## Back up the PostgreSQL database
	./scripts/db-backup.sh

backup-data: ## Back up the /paperclip data volume
	./scripts/data-backup.sh

restore-db: ## Restore PostgreSQL: make restore-db FILE=backups/db/<file>.sql.gz
	@test -n "$(FILE)" || { echo "Usage: make restore-db FILE=backups/db/<file>.sql.gz"; exit 1; }
	./scripts/db-restore.sh "$(FILE)"

restore-data: ## Restore data volume: make restore-data FILE=backups/data/<file>.tar.gz
	@test -n "$(FILE)" || { echo "Usage: make restore-data FILE=backups/data/<file>.tar.gz"; exit 1; }
	./scripts/data-restore.sh "$(FILE)"
