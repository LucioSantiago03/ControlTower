#!/usr/bin/env bash
# Dá ao app (o service principal dele) acesso de leitura à gold e à silver.
#
# O app é um usuário do Unity Catalog e nasce SEM acesso: sem isto o build do app
# falha no typegen com INSUFFICIENT_PERMISSIONS. Rode depois do 1º `bundle deploy`
# do app e antes do `databricks apps deploy`.
#
# Uso:
#   bash scripts/conceder-acesso.sh <perfil> [app] [warehouse_id]
#   bash scripts/conceder-acesso.sh DEFAULT minha-torre
set -euo pipefail

# No Git Bash do Windows, '/api/2.0/...' viraria 'C:/Program Files/Git/api/...' (Not Found).
# Em Linux e Mac esta variável não faz nada.
export MSYS_NO_PATHCONV=1

PERFIL="${1:?informe o perfil do ~/.databrickscfg: bash scripts/conceder-acesso.sh <perfil> [app] [warehouse_id]}"
APP="${2:-minha-torre}"
CATALOGO="lakehouse_vertice"

# 1. O service principal do app (é o "usuário" que o Unity Catalog enxerga)
SP=$(databricks apps get "$APP" --profile "$PERFIL" -o json \
  | sed -n 's/.*"service_principal_client_id": *"\([^"]*\)".*/\1/p' | head -n 1)
if [ -z "$SP" ]; then
  echo "Não achei o service_principal_client_id do app '$APP'. Ele já foi criado com 'databricks bundle deploy'?" >&2
  exit 1
fi

# 2. O warehouse que roda os GRANTs (o Free Edition tem um só)
WAREHOUSE="${3:-$(databricks warehouses list --profile "$PERFIL" -o json \
  | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -n 1)}"

echo "app: $APP · service principal: $SP · warehouse: $WAREHOUSE"

# 3. Os GRANTs: entrar no catálogo, entrar nos schemas e ler as tabelas
GRANTS=(
  "GRANT USE CATALOG ON CATALOG $CATALOGO TO \`$SP\`"
  "GRANT USE SCHEMA, SELECT ON SCHEMA $CATALOGO.gold TO \`$SP\`"
  "GRANT USE SCHEMA, SELECT ON SCHEMA $CATALOGO.silver TO \`$SP\`"
)

for SQL in "${GRANTS[@]}"; do
  RESPOSTA=$(databricks api post /api/2.0/sql/statements --profile "$PERFIL" --json "{
    \"warehouse_id\": \"$WAREHOUSE\",
    \"statement\": \"$(printf '%s' "$SQL" | sed 's/"/\\"/g')\",
    \"wait_timeout\": \"50s\"
  }")
  if printf '%s' "$RESPOSTA" | grep -q '"state": *"SUCCEEDED"'; then
    echo "ok     $SQL"
  else
    echo "FALHOU $SQL" >&2
    printf '%s\n' "$RESPOSTA" >&2
    exit 1
  fi
done

echo "Pronto. Agora, dentro da pasta do app: databricks apps deploy --profile $PERFIL"
