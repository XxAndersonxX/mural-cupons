#!/usr/bin/env bash
# Simula um SQL Editor que executa CADA COMANDO da migração numa conexão e
# transação separadas (nada de sessão, tabela temporária ou BEGIN/COMMIT
# atravessa de um comando para o outro).
#
# Verifica, para a migração 002:
#   1. aplicada comando a comando: sem erros, mensagem de PRIMEIRA aplicação,
#      funções e privilégios corretos (tests/04_permissoes.sql) e regras ok
#   2. reaplicada comando a comando e pelo arquivo inteiro: mensagem de
#      REAPLICAÇÃO e contador em public.migracoes
#   3. falha no meio (execução interrompida) + nova execução completa:
#      termina igual, sem duplicar nada (idempotência)
#   4. down comando a comando e nova aplicação comando a comando
#
# Uso: PSQL_BASE="psql -h HOST -p PORTA -U postgres" ./tests/08_editor_separado.sh
set -Eeuo pipefail
: "${PSQL_BASE:?defina PSQL_BASE}"
cd "$(dirname "$0")/.."
DB=mural_editor_$$
TMP=$(mktemp -d)
trap '$PSQL_BASE -q -X -c "drop database if exists $DB" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
P="$PSQL_BASE -q -X -A -t -v ON_ERROR_STOP=1 -d $DB"

# executa um arquivo comando a comando, cada um num psql (conexão) próprio.
# $2 (opcional) = parar depois de N comandos (simula interrupção no meio)
por_comando() {
  local arq=$1 limite=${2:-0} n=0
  python3 -I tests/separar_sql.py "$arq" > "$TMP/cmds"
  : > "$TMP/notices"
  while IFS= read -r -d '' cmd || [ -n "$cmd" ]; do
    n=$((n + 1))
    if ! $P -c "$cmd" >>"$TMP/saida" 2>"$TMP/err"; then
      { echo "ERRO no comando $n de $arq:"; head -c 400 <<<"$cmd"; echo; cat "$TMP/err"; } >&2; return 1
    fi
    grep -h "NOTICE:  MIGRAÇÃO" "$TMP/err" >> "$TMP/notices" || true
    [ "$limite" -gt 0 ] && [ "$n" -ge "$limite" ] && break
  done < "$TMP/cmds"
  echo "$n"
}
ok() { echo "ok  $*"; }
# exige "descrição" comando...  -> falha o teste inteiro se o comando der falso
exige() { local d=$1; shift; if "$@"; then ok "$d"; else echo "FALHOU: $d"; exit 1; fi; }

$PSQL_BASE -q -X -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null
$P -f tests/00_simular_supabase.sql >/dev/null
$P -f supabase.sql >/dev/null 2>&1
$P -f tests/01_dados_existentes.sql >/dev/null
$P -f migrations/001_membros.sql >/dev/null 2>&1
$P -c "select public.definir_primeiro_admin('anderson');" >/dev/null
COPIAS_ANTES=$($P -c "select count(*) from public.copias")

total=$(python3 -I tests/separar_sql.py migrations/002_copias_ranking.sql | tr -cd '\0' | wc -c); total=$((total + 1))
echo "== 002 tem $total comandos; cada um roda numa conexão separada"

# 1. primeira aplicação
n=$(por_comando migrations/002_copias_ranking.sql | tail -n 1)
[ "$n" = "$total" ] || { echo "executou $n de $total"; exit 1; }
grep -q "MIGRAÇÃO 002 APLICADA" "$TMP/notices" || { echo "faltou a mensagem de primeira aplicação"; cat "$TMP/notices"; exit 1; }
ok "1. 002 aplicada comando a comando ($total conexões): $(sed 's/.*NOTICE:  //' "$TMP/notices")"
exige "   migracoes.aplicacoes = 1" [ "$($P -c "select aplicacoes from public.migracoes where versao='002_copias_ranking'")" = 1 ]
exige "   cópias existentes intactas ($COPIAS_ANTES)" [ "$($P -c "select count(*) from public.copias")" = "$COPIAS_ANTES" ]
$P -f tests/04_permissoes.sql > "$TMP/perm" 2>&1 || { cat "$TMP/perm"; exit 1; }
ok "   $(tail -n 1 "$TMP/perm")"
for f in copiar_codigo_v2 pegar_lote recuperar_lote meus_lotes resumo_lote; do
  $P -c "select 1 from pg_proc where proname = '$f'" | grep -q 1 || { echo "função $f ausente"; exit 1; }
done
ok "   5 funções novas presentes; coluna aproveitados: $($P -c "select count(*) from information_schema.columns where table_name='ranking' and column_name='aproveitados'")"
$P >/dev/null <<'SQL'
insert into public.usuarios (id, nome, papel) values ('ed_a', 'eda', 'membro'), ('ed_b', 'edb', 'membro');
insert into public.codigos (plataforma, codigo, autor_id) values ('Sorte25', 'ED1', 'ed_a'), ('Sorte25', 'ED2', 'ed_a');
select teste.como('ed_b', 'edb'); set role authenticated;
select teste.ok((public.pegar_lote('Sorte25', 5) ->> 'registrados')::int = 2, 'lote funciona após aplicação separada');
select teste.ok((public.copiar_codigo_v2((select id from public.codigos where codigo = 'ED1')) ->> 'status') = 'ja_copiado', 'v2 funciona após aplicação separada');
SQL
ok "   lote e cópia v2 funcionando"

# 2. reaplicação: comando a comando e arquivo inteiro
por_comando migrations/002_copias_ranking.sql >/dev/null
grep -q "MIGRAÇÃO 002 REAPLICADA (execução nº 2)" "$TMP/notices" || { echo "esperava REAPLICADA nº 2"; cat "$TMP/notices"; exit 1; }
ok "2. reaplicada comando a comando: $(sed 's/.*NOTICE:  //' "$TMP/notices")"
$P -f migrations/002_copias_ranking.sql > /dev/null 2> "$TMP/err"
grep -q "REAPLICADA (execução nº 3)" "$TMP/err" || { echo "esperava REAPLICADA nº 3"; cat "$TMP/err"; exit 1; }
ok "   reaplicada pelo arquivo inteiro: execução nº 3"

# 3. interrupção no meio + nova execução completa (banco limpo da 002)
$P -f migrations/002_copias_ranking_down.sql >/dev/null 2>&1
$P -c "delete from public.migracoes where versao = '002_copias_ranking';
       alter table public.copias drop column if exists lote_id;" >/dev/null 2>&1
metade=$((total / 2))
por_comando migrations/002_copias_ranking.sql "$metade" >/dev/null
exige "3. interrompida no comando $metade de $total (sem mensagem final, como esperado)" [ ! -s "$TMP/notices" ]
exige "   migracoes ainda sem registro da 002 (o registro é o último passo)" [ "$($P -c "select count(*) from public.migracoes where versao='002_copias_ranking'")" = 0 ]
por_comando migrations/002_copias_ranking.sql >/dev/null
grep -q "MIGRAÇÃO 002 APLICADA" "$TMP/notices" || { echo "nova execução não terminou como primeira aplicação"; cat "$TMP/notices"; exit 1; }
ok "   nova execução completa terminou: $(sed 's/.*NOTICE:  //' "$TMP/notices")"
$P -f tests/04_permissoes.sql > "$TMP/perm" 2>&1 || { cat "$TMP/perm"; exit 1; }
ok "   $(tail -n 1 "$TMP/perm")"
exige "   índices sem duplicação" [ "$($P -c "select count(*) from pg_indexes where indexname in ('copias_lote','copias_usuario_lote')")" = 2 ]

# 4. down e nova aplicação, comando a comando
por_comando migrations/002_copias_ranking_down.sql >/dev/null
exige "4. down comando a comando: funções removidas" [ "$($P -c "select count(*) from pg_proc where proname in ('pegar_lote','copiar_codigo_v2')")" = 0 ]
exige "   migracoes marca a reversão" [ "$($P -c "select revertida_em is not null from public.migracoes where versao='002_copias_ranking'")" = t ]
por_comando migrations/002_copias_ranking.sql >/dev/null
exige "   reaplicada após o down: $(sed 's/.*NOTICE:  //' "$TMP/notices")" grep -q "REAPLICADA" "$TMP/notices"
$P -f tests/04_permissoes.sql > "$TMP/perm" 2>&1 || { cat "$TMP/perm"; exit 1; }
ok "   $(tail -n 1 "$TMP/perm")"

echo "TODOS OS TESTES DE EXECUÇÃO SEPARADA PASSARAM"
