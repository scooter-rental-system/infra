#!/bin/bash
# ==============================================================================
# Scooter Rental System - Production .env Validation
# Fails when a required value is missing or still a template placeholder.
# Prints key names only, never values.
# Usage: ./check-env.sh [env_file] [template_file] (default: .env .env.example)
# ==============================================================================

set -euo pipefail

ENV_FILE="${1:-.env}"
TEMPLATE_FILE="${2:-.env.example}"

if [ ! -f "$ENV_FILE" ]; then
    echo "ERROR: $ENV_FILE not found."
    exit 1
fi

# Value of a key as Docker Compose reads it: the last assignment wins, surrounding quotes are removed and an
# unquoted value ends at " #".
env_value() {
    local file="$1" key="$2" value
    [ -f "$file" ] || return 0
    value="$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=" "$file" | tail -n 1 | cut -d= -f2- || true)"
    value="${value%$'\r'}"
    value="${value#"${value%%[![:space:]]*}"}"
    case "$value" in
        \"*\") value="${value:1:${#value}-2}" ;;
        \'*\') value="${value:1:${#value}-2}" ;;
        *)
            value="${value%% #*}"
            value="${value%"${value##*[![:space:]]}"}"
            ;;
    esac
    printf '%s' "$value"
}

# True when the value is the template's value or still reads like a placeholder.
is_placeholder() {
    local value="$1" template="$2" lower
    if [ -n "$template" ] && [ "$value" = "$template" ]; then
        return 0
    fi
    lower="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
        *change_me*|*change_this*|*changeme*|*your_*|*_here*|*placeholder*|*example*) return 0 ;;
    esac
    return 1
}

PROBLEMS=0
problem() {
    echo "  - $1"
    PROBLEMS=$((PROBLEMS + 1))
}

echo ">>> Checking $ENV_FILE (values are never printed)..."

# Required settings whose template value may be a valid production value.
for key in POSTGRES_DB POSTGRES_USER CORS_ORIGINS APP_FRONTEND_URL; do
    if [ -z "$(env_value "$ENV_FILE" "$key")" ]; then
        problem "MISSING: $key"
    fi
done

# docker-compose.prod.yml turns an empty PAYMENTS_PROVIDER into stripe, and the backend refuses any other provider,
# so the Stripe keys are always required.
PAYMENTS_PROVIDER_VALUE="$(env_value "$ENV_FILE" PAYMENTS_PROVIDER)"
if [ -n "$PAYMENTS_PROVIDER_VALUE" ] && [ "$PAYMENTS_PROVIDER_VALUE" != "stripe" ]; then
    problem "UNSUPPORTED: PAYMENTS_PROVIDER must be stripe (or empty, which docker-compose.prod.yml turns into stripe)"
fi

# Secrets: must be set and must not be a placeholder.
SECRET_KEYS=(POSTGRES_PASSWORD JWT_SECRET GPS_DEVICE_API_KEY STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY STRIPE_WEBHOOK_SECRET)

for key in "${SECRET_KEYS[@]}"; do
    value="$(env_value "$ENV_FILE" "$key")"
    if [ -z "$value" ]; then
        problem "MISSING: $key"
    elif is_placeholder "$value" "$(env_value "$TEMPLATE_FILE" "$key")"; then
        problem "PLACEHOLDER: $key still has a template value"
    fi
done

# The backend rejects a JWT secret shorter than 32 bytes at startup; fail before building anything.
JWT_VALUE="$(env_value "$ENV_FILE" JWT_SECRET)"
if [ -n "$JWT_VALUE" ] && [ "${#JWT_VALUE}" -lt 32 ]; then
    problem "TOO SHORT: JWT_SECRET must be at least 32 characters"
fi

# Stripe keys of the wrong kind (for example a publishable key pasted as the secret key).
check_prefix() {
    local key="$1" pattern="$2" description="$3" value
    value="$(env_value "$ENV_FILE" "$key")"
    if [ -n "$value" ] && [[ ! "$value" =~ $pattern ]]; then
        problem "WRONG FORMAT: $key must start with $description"
    fi
}
check_prefix STRIPE_SECRET_KEY '^(sk|rk)_' "sk_ or rk_"
check_prefix STRIPE_PUBLISHABLE_KEY '^pk_' "pk_"
check_prefix STRIPE_WEBHOOK_SECRET '^whsec_' "whsec_"

# The backend reads the database password from POSTGRES_PASSWORD; a different SPRING_DATASOURCE_PASSWORD in .env is
# ignored by docker-compose.prod.yml and only causes confusion.
if [ "$(env_value "$ENV_FILE" SPRING_DATASOURCE_PASSWORD)" != "" ] \
    && [ "$(env_value "$ENV_FILE" SPRING_DATASOURCE_PASSWORD)" != "$(env_value "$ENV_FILE" POSTGRES_PASSWORD)" ]; then
    echo "  WARNING: SPRING_DATASOURCE_PASSWORD differs from POSTGRES_PASSWORD; docker-compose.prod.yml uses POSTGRES_PASSWORD."
fi

# Warnings that do not block the deployment.
if [ "$(env_value "$ENV_FILE" NOTIFICATIONS_EMAIL_PROVIDER)" = "ses" ] \
    && [ -z "$(env_value "$ENV_FILE" AWS_ACCESS_KEY_ID)" ]; then
    echo "  WARNING: NOTIFICATIONS_EMAIL_PROVIDER=ses without AWS_ACCESS_KEY_ID needs an EC2 instance role with SES access."
fi
PERMISSIONS="$(stat -c '%a' "$ENV_FILE" 2>/dev/null || echo "")"
if [ -n "$PERMISSIONS" ] && [ "$PERMISSIONS" != "600" ] && [ "$PERMISSIONS" != "400" ]; then
    echo "  WARNING: $ENV_FILE has permissions $PERMISSIONS; restrict it with: chmod 600 $ENV_FILE"
fi

if [ "$PROBLEMS" -gt 0 ]; then
    echo "ERROR: $PROBLEMS production setting(s) must be fixed in $ENV_FILE before deploying."
    exit 1
fi

echo ">>> Production configuration check passed."
