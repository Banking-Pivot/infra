#!/bin/sh
# Starts Vault in dev mode and loads what the banking services need:
#   - their secrets, under secret/<service>/dev (secret/config-server for the Config Server);
#   - one policy per service that only reads its own secrets;
#   - one AppRole per service, whose role ID and secret ID go to
#     /vault/approle/<service>.properties (infra/.secrets on the host), the file each
#     service imports at startup.
# Dev mode keeps everything in memory, so this runs on every start of the container and
# every start issues new secret IDs.
set -eu

SERVICES="config-server customer-service account-service credit-service product-service transaction-service card-service yanki-service auth-service"

rm -f /tmp/bootstrap-done
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN="$VAULT_DEV_ROOT_TOKEN_ID"

vault server -dev -dev-listen-address=0.0.0.0:8200 &
VAULT_PID=$!
trap 'kill "$VAULT_PID"' TERM INT

until vault status >/dev/null 2>&1; do sleep 1; done

vault kv put secret/customer-service/dev \
    spring.mongodb.username="$CUSTOMER_DB_USERNAME" \
    spring.mongodb.password="$CUSTOMER_DB_PASSWORD"

# Flyway connects over JDBC with its own user and password.
vault kv put secret/account-service/dev \
    spring.r2dbc.username="$ACCOUNT_DB_USERNAME" \
    spring.r2dbc.password="$ACCOUNT_DB_PASSWORD" \
    spring.flyway.user="$ACCOUNT_DB_USERNAME" \
    spring.flyway.password="$ACCOUNT_DB_PASSWORD" \
    account.clients.auth.client-secret="$ACCOUNT_SERVICE_CLIENT_SECRET"

vault kv put secret/credit-service/dev \
    spring.r2dbc.username="$CREDIT_DB_USERNAME" \
    spring.r2dbc.password="$CREDIT_DB_PASSWORD" \
    credit.clients.auth.client-secret="$CREDIT_SERVICE_CLIENT_SECRET"

# MongoDB user and the password of the Redis cache.
vault kv put secret/product-service/dev \
    spring.mongodb.username="$PRODUCT_DB_USERNAME" \
    spring.mongodb.password="$PRODUCT_DB_PASSWORD" \
    spring.data.redis.password="$PRODUCT_REDIS_PASSWORD"

# Flyway connects over JDBC with its own user and password.
vault kv put secret/transaction-service/dev \
    spring.r2dbc.username="$TRANSACTION_DB_USERNAME" \
    spring.r2dbc.password="$TRANSACTION_DB_PASSWORD" \
    spring.flyway.user="$TRANSACTION_DB_USERNAME" \
    spring.flyway.password="$TRANSACTION_DB_PASSWORD"

vault kv put secret/card-service/dev \
    spring.r2dbc.username="$CARD_DB_USERNAME" \
    spring.r2dbc.password="$CARD_DB_PASSWORD" \
    spring.flyway.user="$CARD_DB_USERNAME" \
    spring.flyway.password="$CARD_DB_PASSWORD"

vault kv put secret/yanki-service/dev \
    spring.r2dbc.username="$YANKI_DB_USERNAME" \
    spring.r2dbc.password="$YANKI_DB_PASSWORD" \
    spring.flyway.user="$YANKI_DB_USERNAME" \
    spring.flyway.password="$YANKI_DB_PASSWORD"

# auth-service also gets the password of the first administrator, the secret that encrypts
# its signing key at rest and the secret of every service allowed to ask for a service token.
# account-service and credit-service find their own secret under their own path, above.
vault kv put secret/auth-service/dev \
    spring.r2dbc.username="$AUTH_DB_USERNAME" \
    spring.r2dbc.password="$AUTH_DB_PASSWORD" \
    spring.flyway.user="$AUTH_DB_USERNAME" \
    spring.flyway.password="$AUTH_DB_PASSWORD" \
    auth.bootstrap.admin-password="$AUTH_ADMIN_PASSWORD" \
    auth.jwt.key-encryption-secret="$AUTH_KEY_ENCRYPTION_SECRET" \
    auth.service-clients.account-service="$ACCOUNT_SERVICE_CLIENT_SECRET" \
    auth.service-clients.credit-service="$CREDIT_SERVICE_CLIENT_SECRET"

# Only needed by the git backend of the Config Server against a private repository.
if [ -n "$CONFIG_GIT_TOKEN" ]; then
    vault kv put secret/config-server \
        spring.cloud.config.server.git.username="$CONFIG_GIT_USERNAME" \
        spring.cloud.config.server.git.password="$CONFIG_GIT_TOKEN"
fi

vault auth enable approle

for service in $SERVICES; do
    vault policy write "$service" - <<EOF
path "secret/data/$service" { capabilities = ["read"] }
path "secret/data/$service/*" { capabilities = ["read"] }
EOF
    vault write "auth/approle/role/$service" token_policies="$service" token_ttl=1h token_max_ttl=24h
    role_id=$(vault read -field=role_id "auth/approle/role/$service/role-id")
    secret_id=$(vault write -f -field=secret_id "auth/approle/role/$service/secret-id")
    printf 'spring.cloud.vault.app-role.role-id=%s\nspring.cloud.vault.app-role.secret-id=%s\n' \
        "$role_id" "$secret_id" > "/vault/approle/$service.properties"
done

touch /tmp/bootstrap-done
echo "Vault ready: secrets, policies and AppRoles loaded for $SERVICES"

wait "$VAULT_PID"
