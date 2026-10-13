# Shortcuts for the most common tasks. Run "make help".
.DEFAULT_GOAL := help
TAG ?= local

help:            ## show this help
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  %-16s %s\n",$$1,$$2}'

setup:           ## prepare this Linux machine (Docker, tools)
	sudo ./scripts/setup.sh --tools all

test:            ## repository tests (syntax, YAML, JSON, assets, analyzer)
	./scripts/test.sh

up:              ## start the site (Nginx proxy + web)
	./scripts/deploy.sh compose up

up-all:          ## start the site + monitoring + ELK logging
	./scripts/deploy.sh compose up --monitoring --logging

down:            ## stop everything
	./scripts/deploy.sh compose down

health:          ## health check of http://localhost
	./scripts/health-check.sh --url http://localhost --compose

build:           ## build the Docker image (TAG=...)
	./scripts/deploy.sh build --tag $(TAG)

scan:            ## secret, dependency and image scan
	./security/scan-secrets.sh && ./security/scan-dependencies.sh && ./security/scan-image.sh local/nexvion-web:$(TAG)

backup:          ## back up the site and configuration
	./scripts/backup.sh

clean:           ## remove unused Docker data and old backups
	./scripts/cleanup.sh

analyze:         ## AI incident analysis of the running containers
	./ai/incident-analysis/run.sh docker

dashboards:      ## regenerate the Grafana dashboards
	python3 monitoring/grafana/build_dashboards.py

sync-config:     ## copy docker/nginx/default.conf into Kubernetes and Helm
	./scripts/sync-config.sh
