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
    echo "Please update $INFRA_DIR/.env with real secrets before production traffic!"
fi

# 3. Build and launch containers
echo ">>> Building and starting Docker services..."
export BACKEND_PATH="$BACKEND_DIR"
export FRONTEND_PATH="$FRONTEND_DIR"
export INFRA_DOCKER_PATH="docker"

docker compose -f docker-compose.prod.yml build --pull
docker compose -f docker-compose.prod.yml up -d --remove-orphans

# 4. Healthcheck verification
echo ">>> Verifying service health..."
MAX_ATTEMPTS=20
WAIT_SECONDS=3
FRONTEND_HEALTHY=0
BACKEND_HEALTHY=0

for i in $(seq 1 $MAX_ATTEMPTS); do
    echo "Healthcheck attempt $i/$MAX_ATTEMPTS..."
    
    # Check Frontend & Nginx routing
    if curl -s -f -o /dev/null "http://localhost/"; then
        FRONTEND_HEALTHY=1
    fi

    # Check Backend container status
    BACKEND_STATUS=$(docker inspect --format='{{json .State.Health.Status}}' scooter-prod-backend 2>/dev/null || echo '"unknown"')
    if [ "$BACKEND_STATUS" = '"healthy"' ] || [ "$BACKEND_STATUS" = '"running"' ]; then
        BACKEND_HEALTHY=1
    fi

    if [ "$FRONTEND_HEALTHY" -eq 1 ] && [ "$BACKEND_HEALTHY" -eq 1 ]; then
        echo ">>> All services are healthy!"
        break
    fi

    sleep $WAIT_SECONDS
done

if [ "$FRONTEND_HEALTHY" -ne 1 ] || [ "$BACKEND_HEALTHY" -ne 1 ]; then
    echo "ERROR: Deployment health check failed!"
    echo ">>> Backend Logs:"
    docker compose -f docker-compose.prod.yml logs --tail=40 backend
    echo ">>> Frontend Logs:"
    docker compose -f docker-compose.prod.yml logs --tail=40 frontend
    exit 1
fi

# 5. Clean up old dangling Docker images
echo ">>> Pruning dangling images..."
docker image prune -f || true

echo "=============================================================================="
echo "Deployment Succeeded Successfully!"
echo "Public Endpoint: http://65.0.5.214"
echo "=============================================================================="
