#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ENV_FILE="${LOCAL_ENV_FILE:-.env.local}"
COMPOSE=(docker compose -f docker-compose.local.yml --env-file "$ENV_FILE")

usage() {
  printf 'Uso: %s {up|down|restart|status|logs|supabase-status|reset}\n' "$0"
}

require_env() {
  if [[ ! -s "$ENV_FILE" ]]; then
    printf 'Erro: %s não existe. Execute ./ubuntu-local-installer.sh primeiro.\n' "$ENV_FILE" >&2
    exit 1
  fi
}

ensure_supabase() {
  if ! ./scripts/local-supabase.sh status >/dev/null 2>&1; then
    ./scripts/local-supabase.sh start
  fi
}

ensure_encryption_key() {
  local key db_url
  key="$(awk -F= '$1 == "NUVEMSHOP_OAUTH_ENCRYPTION_KEY" { sub(/^[^=]*=/, ""); print; exit }' "$ENV_FILE")"
  if [[ -z "$key" ]]; then
    key="$(openssl rand -hex 32)"
    printf '\nNUVEMSHOP_OAUTH_ENCRYPTION_KEY=%s\n' "$key" >> "$ENV_FILE"
  fi
  db_url="$(./scripts/local-supabase.sh status | node -e 'let s=""; process.stdin.on("data", c => s += c).on("end", () => process.stdout.write(JSON.parse(s).DB_URL || ""))')"
  [[ -n "$db_url" ]] || { printf 'Erro: Supabase local não retornou DB_URL.\n' >&2; exit 1; }
  docker run --rm --network host postgres:15-alpine psql "$db_url" -v ON_ERROR_STOP=1 -c \
    "insert into private.app_secrets (name, value) values ('nuvemshop_oauth_key', '$key') on conflict (name) do update set value = excluded.value, updated_at = now();" \
    >/dev/null
}

# LOCAL_IMAGES=publicadas troca a construção local pelas imagens que o CI
# publicou: é o que um cliente recebe, e não exige memória para compilar.
# O namespace sai do IMG_NS do kit — nunca de um literal aqui.
usar_imagens_publicadas() {
  case "${LOCAL_IMAGES:-}" in
    "") return 1 ;;
    publicadas) ;;
    *)
      printf 'Erro: LOCAL_IMAGES=%s não existe; use LOCAL_IMAGES=publicadas.\n' "$LOCAL_IMAGES" >&2
      exit 2
      ;;
  esac
  local ns tag="${LOCAL_IMAGES_TAG:-stable}"
  ns="$(sed -n 's/^IMG_NS="\([^"]*\)"$/\1/p' hostgator-setup-kit/_common.sh)"
  [[ -n "$ns" ]] || { printf 'Erro: não achei IMG_NS em hostgator-setup-kit/_common.sh.\n' >&2; exit 1; }
  export LOCAL_APP_IMAGE="$ns/deskcommcrm:$tag"
  export LOCAL_WORKER_IMAGE="$ns/deskcomm-worker:$tag"
  export LOCAL_SCHEDULER_IMAGE="$ns/deskcomm-scheduler:$tag"
  export LOCAL_PULL_POLICY=missing
  printf 'Usando imagens publicadas: %s (tag %s)\n' "$ns" "$tag"
}

case "${1:-}" in
  up)
    ensure_supabase
    ./scripts/local-env.sh ensure
    require_env
    ensure_encryption_key
    if usar_imagens_publicadas; then
      "${COMPOSE[@]}" pull app worker scheduler
      "${COMPOSE[@]}" up -d --no-build
    else
      "${COMPOSE[@]}" up -d --build
    fi
    ;;
  down)
    "${COMPOSE[@]}" down
    ./scripts/local-supabase.sh stop || true
    ;;
  restart)
    require_env
    "${COMPOSE[@]}" restart
    ;;
  status)
    require_env
    ./scripts/local-supabase.sh status
    "${COMPOSE[@]}" ps
    ;;
  logs)
    require_env
    "${COMPOSE[@]}" logs -f --tail=200 "${2:-app}"
    ;;
  supabase-status)
    ./scripts/local-supabase.sh status
    ;;
  reset)
    require_env
    "${COMPOSE[@]}" down
    ./scripts/local-supabase.sh stop
    ./scripts/local-supabase.sh start
    usar_imagens_publicadas || true
    "${COMPOSE[@]}" up -d
    ;;
  *)
    usage
    exit 2
    ;;
esac
