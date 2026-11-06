#!/usr/bin/env bash
# Roda toda a bateria num Postgres LOCAL descartável (nunca no Supabase).
# Uso: PSQL_BASE="psql -h HOST -p PORTA -U postgres" ./tests/rodar_local.sh
set -euo pipefail
: "${PSQL_BASE:?defina PSQL_BASE}"
cd "$(dirname "$0")/.."
DB=mural_teste_$$
$PSQL_BASE -q -X -c "create database $DB" >/dev/null
trap '$PSQL_BASE -q -X -c "drop database if exists $DB" >/dev/null' EXIT
P="$PSQL_BASE -q -X -A -t -v ON_ERROR_STOP=1 -d $DB"
run() { echo "== $1"; $P -f "$1" 2>&1 | grep -vE '^$|NOTICE' || true; }

$P -f tests/00_simular_supabase.sql >/dev/null
$P -f supabase.sql 2>&1 | grep -v NOTICE || true
$P -f tests/01_dados_existentes.sql >/dev/null
echo "== migração 001";        $P -f migrations/001_membros.sql
run tests/02_membros.sql
echo "== concorrência";        PSQL="$PSQL_BASE -d $DB" tests/03_concorrencia.sh

echo "== reversão (down)"
$P -f migrations/001_membros_down.sql
$P -c "select teste.ok((select count(*) from public.codigos) >= (select codigos from teste.antes), 'down: códigos preservados');"
$P -c "select teste.ok((select count(*) from public.copias)  >= (select copias  from teste.antes), 'down: cópias preservadas');"
$P -c "select teste.como('u_x','qualquer'); set role authenticated; select teste.ok(public.entrar() = 'qualquer', 'down: entrar() antigo de volta (texto)');"
$P -c "select teste.ok(exists (select 1 from information_schema.columns where table_name='usuarios' and column_name='papel'), 'down: papéis guardados (não destrutivo)');"

echo "== reaplicar 001 (idempotência)"
$P -f migrations/001_membros.sql
$P -c "select teste.ok(exists (select 1 from public.usuarios where papel='admin'), 'reaplicar: admins mantidos');"
$P -c "select teste.como('u_x','qualquer'); set role authenticated; select teste.ok((public.entrar() ->> 'papel') = 'pendente', 'reaplicar: conta criada no down é pendente');"
echo "BATERIA COMPLETA OK"
