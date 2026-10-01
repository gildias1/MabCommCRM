#!/usr/bin/env bash
# Prova as duas garantias do instalador local: ele não apaga o ambiente de
# quem já usa o clone, e a senha do dono não nasce publicada.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
INSTALADOR="$ROOT_DIR/ubuntu-local-installer.sh"
STACK="$ROOT_DIR/scripts/local-stack.sh"
SUPA="$ROOT_DIR/scripts/local-supabase.sh"
ENVGEN="$ROOT_DIR/scripts/local-env.sh"
COMPOSE="$ROOT_DIR/docker-compose.local.yml"
FAILS=0

check() {
  local descricao="$1"
  shift
  if "$@"; then
    printf '  ✓ %s\n' "$descricao"
  else
    printf '  ✗ %s\n' "$descricao"
    FAILS=$((FAILS + 1))
  fi
}

echo "stack local — instalador e scripts"

for arquivo in "$INSTALADOR" "$STACK" "$SUPA" "$ENVGEN"; do
  check "sintaxe Bash válida: ${arquivo#"$ROOT_DIR"/}" bash -n "$arquivo"
done

# ── A senha do dono ────────────────────────────────────────────────────────
#
# O instalador publica as credenciais na tela no fim. Se a senha for literal
# no arquivo, ela está publicada NO REPOSITÓRIO — e o `.env.local` que este
# mesmo script gera aponta a aplicação para o IP da VM na rede, não para
# 127.0.0.1. Qualquer máquina da rede alcançaria o CRM com a senha do GitHub.
check "a senha do dono não é literal no script" bash -c '
  ! grep -qE "^export OWNER_PASSWORD=\"[^$]" "$1"' _ "$INSTALADOR"
check "a senha do dono nasce aleatória" bash -c '
  grep -q "openssl rand" <<<"$(grep "^export OWNER_PASSWORD=" "$1")"' _ "$INSTALADOR"
check "quem quiser escolher a senha consegue (OWNER_PASSWORD respeitado)" bash -c '
  grep -q "OWNER_PASSWORD:-" "$1"' _ "$INSTALADOR"

# ── A chave da API do WAHA ─────────────────────────────────────────────────
#
# Ela comanda a sessão de WhatsApp. Literal no arquivo = publicada NESTE
# repositório — o mesmo argumento da senha do dono, e pior, porque o painel do
# WAHA fica de pé. As duas checagens abaixo EXECUTAM as linhas em vez de as
# lerem: além do literal, elas pegam o erro irmão de derivar a chave e o hash
# de dois `openssl rand` diferentes, que passa em qualquer grep e rende 401.
#
# `sha512sum` é do GNU e não existe no macOS, onde este teste roda antes de
# chegar ao Ubuntu do CI; o stub abaixo o troca por um marcador visível, porque
# o que se prova aqui é a PROCEDÊNCIA do hash, não o algoritmo.
check "instalador: o hash do WAHA deriva da chave, e a chave nasce aleatória" bash -c '
  sha512sum() { sed "s/^/marca:/"; }
  eval "$(grep -E "^WAHA_KEY(_HASH)?=" "$1")"
  [[ "${WAHA_KEY:-}" =~ ^[0-9a-f]{48}$ ]] || exit 1
  [[ "${WAHA_KEY_HASH:-}" == "marca:$WAHA_KEY" ]]
' _ "$INSTALADOR"

check "gerador de .env.local: o hash do WAHA deriva da MESMA chave" bash -c '
  sha512sum() { sed "s/^/marca:/"; }
  waha_key="canario-0123456789"
  eval "$(grep -E "^WAHA_API_KEY(_SHA512)?=" "$1")"
  [[ "${WAHA_API_KEY:-}" == "canario-0123456789" ]] || exit 1
  [[ "${WAHA_API_KEY_SHA512:-}" == "marca:canario-0123456789" ]]
' _ "$ENVGEN"

check "gerador de .env.local: a chave do WAHA nasce aleatória" bash -c '
  grep -qF "waha_key=\"\$(openssl rand" "$1"' _ "$ENVGEN"

# ── O painel do WAHA não atende a rede ─────────────────────────────────────
#
# O dashboard está LIGADO neste compose e tem autenticação própria, com o
# padrão do WAHA — a chave da API não o protege. Publicar a porta sem endereço
# de bind entrega o comando da sessão de WhatsApp a qualquer máquina da rede da
# VM. `docker-compose.prod.yml` fecha o mesmo buraco desligando o dashboard e
# não publicando porta nenhuma; aqui ele serve quem desenvolve, em 127.0.0.1.
#
# Range de awk (`/^  waha:/,/^  [a-z]/`) NÃO serve: `  waha:` casa com o próprio
# padrão de fim e o bloco colapsa em 1 linha — sonda quebrada devolve zero e
# lê exatamente como "nenhuma porta exposta". Por isso a flag `f`, e por isso a
# checagem de controle logo abaixo.
BLOCO_WAHA='awk "/^  waha:/{f=1;next} f && /^  [a-z]/{f=0} f"'
check "a sonda enxerga o bloco do WAHA no compose" bash -c '
  eval "$2" "$1" | grep -q WAHA_DASHBOARD_ENABLED' _ "$COMPOSE" "$BLOCO_WAHA"
check "nenhuma porta do WAHA é publicada sem endereço de bind" bash -c '
  ! eval "$2" "$1" | grep -qE "^ +- \"[0-9]+:[0-9]+\"$"' _ "$COMPOSE" "$BLOCO_WAHA"

# ── O .env.local de quem já usa o clone ────────────────────────────────────
#
# O instalador roda DENTRO de um clone existente (ele só clona quando não acha
# `package.json`), e 93 scripts deste repositório leem `.env.local`. Escrever
# por cima sem cópia apaga o ambiente de trabalho de quem rodar por curiosidade.
check "o instalador faz backup de um .env.local que não é local" bash -c '
  grep -q "cloud-backup" "$1"' _ "$INSTALADOR"
check "o instalador reconhece o ambiente local pela marca DESKCOMM_ENV_MODE" bash -c '
  grep -q "DESKCOMM_ENV_MODE=local" "$1"' _ "$INSTALADOR"
check "o .env.local gerado carrega a marca (senão o próximo run apaga sem backup)" bash -c '
  awk "/^cat <<EOF > .env.local\$/,/^EOF\$/" "$1" | grep -q "^DESKCOMM_ENV_MODE=local\$"' _ "$INSTALADOR"

# ── O COMPORTAMENTO, e não só o texto ──────────────────────────────────────
#
# As checagens acima leem o arquivo; esta EXECUTA o trecho da guarda contra um
# `.env.local` de mentira, que é a única forma de saber que a condição casa.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
guarda() {
  # O mesmo bloco do instalador, extraído por marcador — se ele mudar lá, esta
  # extração falha e o teste fica vermelho em vez de medir um texto obsoleto.
  awk '/^if \[\[ -s .env.local \]\]/,/^fi$/' "$INSTALADOR"
}
[[ -n "$(guarda)" ]] || { printf '  ✗ não achei a guarda no instalador\n'; FAILS=$((FAILS + 1)); }

(
  cd "$TMP_DIR" || exit 1
  paint() { :; }
  printf 'NEXT_PUBLIC_SUPABASE_URL=https://nuvem.supabase.co\n' > .env.local
  eval "$(guarda)"
) >/dev/null 2>&1
check "ambiente da NUVEM é copiado antes de ser substituído" test -s "$TMP_DIR/.env.local.cloud-backup"

(
  cd "$TMP_DIR" || exit 1
  rm -f .env.local.cloud-backup
  paint() { :; }
  printf 'DESKCOMM_ENV_MODE=local\nNEXT_PUBLIC_SUPABASE_URL=http://127.0.0.1:54321\n' > .env.local
  eval "$(guarda)"
) >/dev/null 2>&1
check "ambiente JÁ local não vira backup a cada run" bash -c '! test -e "$1/.env.local.cloud-backup"' _ "$TMP_DIR"

# ── Construir ou usar as imagens publicadas ────────────────────────────────
#
# O padrão continua sendo construir desta pasta. `LOCAL_IMAGES=publicadas`
# troca pelas imagens do CI, com o namespace tirado do IMG_NS do kit. As
# checagens EXECUTAM a função extraída do script, numa raiz de mentira.
check "por padrão o up constrói desta pasta" grep -qF 'up -d --build' "$STACK"
check "o compose segue construindo quando nada é pedido" bash -c '
  grep -qF "image: \${LOCAL_APP_IMAGE:-deskcomm-app:local}" "$1" &&
  grep -qF "pull_policy: \${LOCAL_PULL_POLICY:-never}" "$1"' _ "$COMPOSE"
funcao_imagens() {
  awk '/^usar_imagens_publicadas\(\) \{/,/^\}$/' "$STACK"
}
[[ -n "$(funcao_imagens)" ]] || { printf '  ✗ não achei usar_imagens_publicadas no local-stack.sh\n'; FAILS=$((FAILS + 1)); }
mkdir -p "$TMP_DIR/raiz/hostgator-setup-kit"
printf 'IMG_NS="ghcr.io/dono-de-teste"\n' > "$TMP_DIR/raiz/hostgator-setup-kit/_common.sh"
check "LOCAL_IMAGES=publicadas aponta para o IMG_NS do kit" bash -c '
  cd "$1" && eval "$2"
  LOCAL_IMAGES=publicadas usar_imagens_publicadas >/dev/null &&
  [[ "$LOCAL_APP_IMAGE" == "ghcr.io/dono-de-teste/deskcommcrm:stable" ]] &&
  [[ "$LOCAL_SCHEDULER_IMAGE" == "ghcr.io/dono-de-teste/deskcomm-scheduler:stable" ]] &&
  [[ "$LOCAL_PULL_POLICY" == "missing" ]]' _ "$TMP_DIR/raiz" "$(funcao_imagens)"
check "LOCAL_IMAGES_TAG escolhe a versão" bash -c '
  cd "$1" && eval "$2"
  LOCAL_IMAGES=publicadas LOCAL_IMAGES_TAG=1.69.1 usar_imagens_publicadas >/dev/null &&
  [[ "$LOCAL_WORKER_IMAGE" == "ghcr.io/dono-de-teste/deskcomm-worker:1.69.1" ]]' _ "$TMP_DIR/raiz" "$(funcao_imagens)"
check "sem LOCAL_IMAGES nada muda (continua construindo)" bash -c '
  cd "$1" && eval "$2"
  unset LOCAL_IMAGES; ! usar_imagens_publicadas' _ "$TMP_DIR/raiz" "$(funcao_imagens)"
check "valor desconhecido em LOCAL_IMAGES é recusado" bash -c '
  cd "$1" && eval "$2"
  ( LOCAL_IMAGES=nuvem usar_imagens_publicadas ) 2>/dev/null; [[ $? -eq 2 ]]' _ "$TMP_DIR/raiz" "$(funcao_imagens)"

# ── O banco visto de dentro do Docker ──────────────────────────────────────
#
# Medido no Docker Desktop (WSL2): o worker reiniciava em ciclo com
# `connect EHOSTUNREACH <IP da VM>:54322`, porque o .env.local aponta o banco
# para o IP da VM e a VM do Docker Desktop não o alcança.
funcao_banco() {
  awk '/^banco_visto_de_dentro_do_docker\(\) \{/,/^\}$/' "$STACK"
}
[[ -n "$(funcao_banco)" ]] || { printf '  ✗ não achei banco_visto_de_dentro_do_docker no local-stack.sh\n'; FAILS=$((FAILS + 1)); }
check "o banco dos contêineres troca o IP da VM por host.docker.internal" bash -c '
  printf "SUPABASE_DB_URL=postgresql://postgres:postgres@172.19.118.200:54322/postgres\n" > "$1/env-banco"
  ENV_FILE="$1/env-banco"; eval "$2"; banco_visto_de_dentro_do_docker
  [[ "$LOCAL_CONTAINER_DB_URL" == "postgresql://postgres:postgres@host.docker.internal:54322/postgres" ]]' _ "$TMP_DIR" "$(funcao_banco)"
check "sem SUPABASE_DB_URL a função não inventa endereço" bash -c '
  : > "$1/env-vazio"; unset LOCAL_CONTAINER_DB_URL
  ENV_FILE="$1/env-vazio"; eval "$2"; banco_visto_de_dentro_do_docker
  [[ -z "${LOCAL_CONTAINER_DB_URL:-}" ]]' _ "$TMP_DIR" "$(funcao_banco)"
check "app, worker e scheduler recebem o banco visto de dentro" bash -c '
  [[ "$(grep -c "SUPABASE_DB_URL: \${LOCAL_CONTAINER_DB_URL:-" "$1")" == 3 ]] &&
  [[ "$(grep -c "SUPABASE_SERVER_URL: \${SUPABASE_SERVER_URL:-http://host.docker.internal:54321}" "$1")" == 3 ]]' _ "$COMPOSE"

if [[ "$FAILS" -gt 0 ]]; then
  printf '\n%s verificação(ões) falharam\n' "$FAILS"
  exit 1
fi
printf '\ntodas as verificações passaram\n'
