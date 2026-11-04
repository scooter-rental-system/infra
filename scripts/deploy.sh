#!/bin/bash
# ==============================================================================
# Scooter Rental System - Production Deployment Script
# Executed on EC2 host to deploy frontend, backend, and database
# Usage: ./deploy.sh [branch_name] (default: develop)
# ==============================================================================

set -euo pipefail

DEPLOY_BRANCH="${1:-develop}"
BASE_DIR="/opt/scooter-rent"
INFRA_DIR="$BASE_DIR/infra"
BACKEND_DIR="$BASE_DIR/backend"
FRONTEND_DIR="$BASE_DIR/frontend"

echo "=============================================================================="
echo "Starting Deployment for branch: $DEPLOY_BRANCH"
echo "Deployment Time: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "=============================================================================="

mkdir -p "$BASE_DIR"
cd "$BASE_DIR"

# Helper function to clone or pull a repo
sync_repo() {
    local repo_url="$1"
    local target_dir="$2"
    local branch="$3"

    if [ ! -d "$target_dir/.git" ]; then
        echo ">>> Cloning $repo_url into $target_dir on branch $branch..."
        git clone --branch "$branch" "$repo_url" "$target_dir"
    else
        echo ">>> Pulling latest changes in $target_dir ($branch)..."
        cd "$target_dir"
        git fetch origin
        git checkout "$branch"
        git pull origin "$branch"
        cd "$BASE_DIR"
    fi
}

# 1. Synchronize repositories
sync_repo "https://github.com/scooter-rental-system/infra.git" "$INFRA_DIR" "$DEPLOY_BRANCH"
sync_repo "https://github.com/scooter-rental-system/backend.git" "$BACKEND_DIR" "$DEPLOY_BRANCH"
sync_repo "https://github.com/scooter-rental-system/frontend.git" "$FRONTEND_DIR" "$DEPLOY_BRANCH"

cd "$INFRA_DIR"

# 2. Check for production environment configuration
if [ ! -f .env ]; then
    echo "WARNING: .env file not found in $INFRA_DIR! Creating template from .env.example..."
    cp .env.example .env
    echo "Fill in $INFRA_DIR/.env with real production values, then run the deployment again."
fi

# 3. Refuse to deploy with missing or placeholder production values (key names only, never values)
echo ">>> Validating production configuration in $INFRA_DIR/.env..."
bash "$INFRA_DIR/scripts/check-env.sh" "$INFRA_DIR/.env" "$INFRA_DIR/.env.example"

# 4. Build and launch containers
echo ">>> Building and starting Docker services..."
export BACKEND_PATH="$BACKEND_DIR"
export FRONTEND_PATH="$FRONTEND_DIR"
# Compose resolves a relative dockerfile path against the build context (the backend/frontend clones), but the
# Dockerfiles live in this infra repository, so the path must be absolute.
export INFRA_DOCKER_PATH="$INFRA_DIR/docker"

docker compose -f docker-compose.prod.yml build --pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans

# 5. Healthcheck verification: the backend container must report "healthy" (its HEALTHCHECK calls /api/health)
#    and both the frontend and the API must answer through Nginx.
echo ">>> Verifying service health..."
MAX_ATTEMPTS=60
WAIT_SECONDS=5
HEALTHY=0
BACKEND_STATUS="unknown"

for i in $(seq 1 $MAX_ATTEMPTS); do
    BACKEND_STATUS=$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}no-healthcheck{{end}}' scooter-prod-backend 2>/dev/null || echo "missing")
    echo "Healthcheck attempt $i/$MAX_ATTEMPTS: backend container is $BACKEND_STATUS"

    if [ "$BACKEND_STATUS" = "unhealthy" ]; then
        break
    fi

    if [ "$BACKEND_STATUS" = "healthy" ] \
        && curl -s -f -o /dev/null "http://localhost/" \
        && curl -s -f -o /dev/null "http://localhost/api/health"; then
        HEALTHY=1
        echo ">>> All services are healthy!"
        break
    fi

    sleep $WAIT_SECONDS
done

if [ "$HEALTHY" -ne 1 ]; then
    echo "ERROR: Deployment health check failed (backend container: $BACKEND_STATUS)!"
    echo ">>> Backend Logs:"
    docker compose -f docker-compose.prod.yml logs --tail=40 backend
    echo ">>> Frontend Logs:"
    docker compose -f docker-compose.prod.yml logs --tail=40 frontend
    exit 1
fi

# 6. Clean up old dangling Docker images
echo ">>> Pruning dangling images..."
docker image prune -f || true

echo "=============================================================================="
echo "Deployment Succeeded Successfully!"
echo "Public Endpoint: http://65.0.5.214"
echo "=============================================================================="
