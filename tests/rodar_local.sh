#!/usr/bin/env bash
# Roda toda a bateria num Postgres LOCAL descartável (nunca no Supabase).
#
# Uso:
#   PSQL_BASE="psql -h HOST -p PORTA -U postgres" ./tests/rodar_local.sh
#   (opcional) PG_HOST=HOST PG_PORT=PORTA POSTGREST=/caminho/postgrest  -> inclui os testes pela API
#
# Qualquer erro de psql, teste ou script interrompe tudo (set -e + pipefail +
# ON_ERROR_STOP). A mensagem final de sucesso só aparece se TODAS as etapas passarem.
set -Eeuo pipefail
: "${PSQL_BASE:?defina PSQL_BASE}"
cd "$(dirname "$0")/.."

DB=mural_teste_$$
ETAPA="início"
LOG=$(mktemp)
falhou() {
  echo
  echo "!!! FALHOU na etapa: $ETAPA"
  echo "--- últimas linhas da saída:"
  tail -n 25 "$LOG" || true
  echo "BATERIA INTERROMPIDA (nenhuma mensagem de sucesso)"
}
trap falhou ERR
trap '$PSQL_BASE -q -X -c "drop database if exists $DB" >/dev/null 2>&1 || true; rm -f "$LOG"' EXIT

P="$PSQL_BASE -q -X -A -t -v ON_ERROR_STOP=1 -d $DB"

# roda um arquivo SQL; falha se o psql falhar; mostra só as linhas de resultado
sql() {
  ETAPA=$1
  echo "== $1"
  $P -f "$2" >"$LOG" 2>&1
  grep -vE '^\s*$|^psql:.*NOTICE:  (constraint|policy|relation|function|table|index) .*(does not exist|already exists), skipping' "$LOG" || true
}
# roda um comando SQL de verificação (teste.ok derruba se falso)
verifica() { ETAPA=$1; $P -c "$2" >"$LOG" 2>&1; cat "$LOG"; }

ETAPA="criar banco"
$PSQL_BASE -q -X -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null

sql "simular Supabase (papéis, auth.jwt)"   tests/00_simular_supabase.sql >/dev/null
sql "banco original (supabase.sql)"         supabase.sql >/dev/null
sql "dados existentes (fluxo antigo)"       tests/01_dados_existentes.sql >/dev/null

sql "migração 001 — PRIMEIRA aplicação"     migrations/001_membros.sql
grep -q "PRIMEIRA APLICAÇÃO" "$LOG" || { ETAPA="aviso de primeira aplicação"; echo "esperava aviso de PRIMEIRA APLICAÇÃO"; false; }

sql "segurança dos membros"                 tests/02_membros.sql
sql "permissões no catálogo"                tests/04_permissoes.sql

ETAPA="concorrência"; echo "== concorrência"
PSQL="$PSQL_BASE -d $DB" tests/03_concorrencia.sh >"$LOG" 2>&1 || { cat "$LOG"; false; }
cat "$LOG"

sql "migração 001 — REAPLICAÇÃO"            migrations/001_membros.sql
grep -q "REAPLICAÇÃO: papéis mantidos" "$LOG" || { ETAPA="aviso de reaplicação"; echo "esperava aviso de REAPLICAÇÃO"; false; }
verifica "reaplicação mantém admins" \
  "select teste.ok(exists (select 1 from public.usuarios where papel='admin' and situacao='ativo'), 'reaplicação: admins mantidos');"
verifica "reaplicação conta execuções" \
  "select teste.ok((select aplicacoes from public.migracoes where versao='001_membros') = 2, 'reaplicação: migracoes.aplicacoes = 2');"
sql "permissões após reaplicação"           tests/04_permissoes.sql | tail -n 1

sql "reversão (down)"                       migrations/001_membros_down.sql
verifica "down preserva códigos" \
  "select teste.ok((select count(*) from public.codigos) >= (select codigos from teste.antes), 'down: códigos preservados');"
verifica "down preserva cópias" \
  "select teste.ok((select count(*) from public.copias) >= (select copias from teste.antes), 'down: cópias preservadas');"
verifica "down restaura entrar() antigo" \
  "select teste.como('u_x','qualquer'); set role authenticated; select teste.ok(public.entrar() = 'qualquer', 'down: entrar() antigo (texto)');"
verifica "down remove entrar_v2" \
  "select teste.ok(not exists (select 1 from pg_proc where proname in ('entrar_v2','admin_alterar_acesso','eh_membro')), 'down: funções novas removidas');"
verifica "down guarda papéis" \
  "select teste.ok(exists (select 1 from information_schema.columns where table_name='usuarios' and column_name='papel'), 'down: papéis guardados (não destrutivo)');"
verifica "down marca migração" \
  "select teste.ok((select revertida_em is not null from public.migracoes where versao='001_membros'), 'down: migracoes.revertida_em preenchido');"

sql "reaplicar 001 depois do down"          migrations/001_membros.sql
grep -q "REAPLICAÇÃO" "$LOG" || { ETAPA="aviso após down"; echo "esperava aviso de REAPLICAÇÃO"; false; }
verifica "após down: admins voltam" \
  "select teste.ok(exists (select 1 from public.usuarios where papel='admin'), 'reaplicar após down: admins mantidos');"
verifica "após down: conta nova é pendente" \
  "select teste.como('u_x','qualquer'); set role authenticated; select teste.ok((public.entrar_v2() ->> 'papel') = 'pendente', 'reaplicar após down: conta criada no intervalo é pendente');"

if [ -n "${POSTGREST:-}" ]; then
  ETAPA="API (PostgREST)"; echo "== permissões pela API (PostgREST)"
  PSQL_BASE="$PSQL_BASE" tests/05_api.sh >"$LOG" 2>&1 || { cat "$LOG"; false; }
  grep -E "^FALHOU|verificações|PASSARAM" "$LOG"
else
  echo "== API: pulada (defina POSTGREST, PG_HOST e PG_PORT para incluir)"
fi

trap - ERR
echo
echo "BATERIA COMPLETA OK — todas as etapas passaram"
