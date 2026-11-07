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

# ===================== FASE 2 (migração 002) =====================
ETAPA="002 exige a 001"; echo "== 002 recusa banco sem a 001"
$P -c "update public.migracoes set revertida_em = now() where versao = '001_membros'" >/dev/null
if $P -f migrations/002_copias_ranking.sql >"$LOG" 2>&1; then echo "a 002 deveria ter sido recusada"; false; fi
grep -q "001_membros precisa estar aplicada" "$LOG"
echo "ok  002 recusada sem a 001 (nada aplicado)"
verifica "002 não deixou rastro" \
  "select teste.ok(to_regproc('public.pegar_lote') is null, '002 recusada não criou nada');"
$P -c "update public.migracoes set revertida_em = null where versao = '001_membros'" >/dev/null

sql "migração 002 — primeira aplicação"     migrations/002_copias_ranking.sql
grep -q "MIGRAÇÃO 002 APLICADA" "$LOG" || { ETAPA="aviso da 002"; echo "esperava aviso de 002 APLICADA"; false; }
verifica "002 preserva cópias" \
  "select teste.ok((select count(*) from public.copias where lote_id is null) = (select count(*) from public.copias), '002: cópias existentes intactas (sem lote)');"

sql "fase 2: cópia, lote, recuperação, aproveitados" tests/06_copias.sql
ETAPA="concorrência do lote"; echo "== concorrência do lote"
PSQL="$PSQL_BASE -d $DB" tests/07_concorrencia_lote.sh >"$LOG" 2>&1 || { cat "$LOG"; false; }
cat "$LOG"
sql "permissões com a 002"                  tests/04_permissoes.sql | tail -n 1

sql "migração 002 — reaplicação"            migrations/002_copias_ranking.sql
grep -q "MIGRAÇÃO 002 REAPLICADA" "$LOG" || { ETAPA="aviso de reaplicação da 002"; echo "esperava 002 REAPLICADA"; false; }

ETAPA="001 down protegido"; echo "== down da 001 recusa enquanto a 002 está ativa"
if $P -f migrations/001_membros_down.sql >"$LOG" 2>&1; then echo "o down da 001 deveria ter sido recusado"; false; fi
grep -q "Reverta a migração 002" "$LOG"
verifica "001 continua inteira" "select teste.ok(to_regproc('public.entrar_v2') is not null, 'down da 001 recusado sem mexer em nada');"

verifica "foto antes do down da 002" "drop table if exists teste.antes2; create table teste.antes2 as select count(*) n from public.copias;"
sql "reversão da 002 (down)"                migrations/002_copias_ranking_down.sql
verifica "down 002: funções removidas" \
  "select teste.ok(to_regproc('public.pegar_lote') is null and to_regproc('public.copiar_codigo_v2') is null, 'down 002: funções novas removidas');"
verifica "down 002: ranking como na 001" \
  "select teste.ok(not exists (select 1 from information_schema.columns where table_name='ranking' and column_name='aproveitados'), 'down 002: ranking sem aproveitados');"
verifica "down 002: cópias preservadas" \
  "select teste.ok((select count(*) from public.copias) = (select n from teste.antes2), 'down 002: nenhuma cópia apagada');"
verifica "down 002: lote_id guardado" \
  "select teste.ok(exists (select 1 from information_schema.columns where table_name='copias' and column_name='lote_id'), 'down 002: coluna lote_id mantida (não destrutivo)');"
verifica "down 002: função antiga ok" \
  "select teste.como('u_anderson','anderson'); set role authenticated; select teste.ok(public.copiar_codigo(-1) = false, 'down 002: copiar_codigo antigo funciona');"
sql "permissões após down da 002"           tests/04_permissoes.sql | tail -n 1

sql "reaplicar 002 depois do down"          migrations/002_copias_ranking.sql
grep -q "MIGRAÇÃO 002 REAPLICADA" "$LOG" || { ETAPA="002 após down"; echo "esperava 002 REAPLICADA"; false; }
sql "permissões finais"                     tests/04_permissoes.sql | tail -n 1

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
