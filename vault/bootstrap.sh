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

SERVICES="config-server customer-service account-service credit-service"

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
    spring.flyway.password="$ACCOUNT_DB_PASSWORD"

vault kv put secret/credit-service/dev \
    spring.r2dbc.username="$CREDIT_DB_USERNAME" \
    spring.r2dbc.password="$CREDIT_DB_PASSWORD"

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
