#!/usr/bin/env bash
# Testes de concorrência (precisam de várias conexões ao mesmo tempo).
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/03_concorrencia.sh
#
# Em corridas, uma das ações PODE falhar de propósito (ex.: o segundo admin já
# não é admin). Essas falhas só são aceitas se o erro for um dos esperados para
# o cenário; qualquer outro erro (sintaxe, permissão, conexão) derruba o teste.
set -euo pipefail
: "${PSQL:?defina PSQL}"
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0

como() { echo "select teste.como('$1', '$2'); set role authenticated;"; }

# roda SQL em segundo plano; grava "ok <saída>" ou "erro <mensagem>"
em_paralelo() {  # arquivo sql...
  local arq=$1; shift
  # em caso de sucesso guarda só a última linha (o resultado do último select)
  ( if out=$($Q -c "$*" 2>&1); then echo "ok $(printf '%s\n' "$out" | sed '/^$/d' | tail -n 1)" > "$arq"
    else echo "erro $(printf '%s' "$out" | tr '\n' ' ')" > "$arq"; fi ) &
}
# confere o resultado: só aceita sucesso ou um erro da lista permitida
aceita() {  # arquivo regex-erros-permitidos rótulo
  local r; r=$(cat "$1")
  if [[ $r == ok* ]]; then return 0; fi
  if [[ -n "$2" && $r =~ $2 ]]; then return 0; fi
  echo "ERRO INESPERADO em $3: $r"; falhas=$((falhas + 1))
}

# Cenário A: dois admins removendo o admin do outro ao mesmo tempo.
for r in $(seq 1 15); do
  $Q -c "update public.usuarios set papel='admin', situacao='ativo' where id in ('u_anderson','u_pedro')"
  em_paralelo "$TMP/a1" "$(como u_anderson anderson) select public.admin_alterar_acesso('u_pedro','remover_admin');"
  em_paralelo "$TMP/a2" "$(como u_pedro pedro) select public.admin_alterar_acesso('u_anderson','remover_admin');"
  wait
  aceita "$TMP/a1" 'nao_admin' "A$r/anderson"; aceita "$TMP/a2" 'nao_admin' "A$r/pedro"
  n=$($Q -c "select count(*) from public.usuarios where papel='admin' and situacao='ativo'")
  if [ "$n" -lt 1 ]; then echo "FALHOU rodada $r: ficou sem admin"; falhas=$((falhas + 1)); fi
  ok=$(grep -l '^ok' "$TMP/a1" "$TMP/a2" | wc -l)
  if [ "$ok" != 1 ]; then echo "FALHOU rodada $r: $ok ações venceram (esperado 1)"; falhas=$((falhas + 1)); fi
done
echo "ok  A: dois admins removendo um ao outro (15 rodadas): exatamente 1 vence, sempre sobra admin"

# Cenário B: dois admins agindo sobre o mesmo pendente (aprovar x rejeitar),
# os dois vendo a mesma versão na tela. Exatamente uma ação vence.
$Q -c "update public.usuarios set papel='admin', situacao='ativo' where id in ('u_anderson','u_pedro')"
for r in $(seq 1 15); do
  $Q -c "insert into public.usuarios (id, nome) values ('u_alvo$r','alvo$r')"
  v=$($Q -c "select atualizado_em from public.usuarios where id='u_alvo$r'")
  em_paralelo "$TMP/b1" "$(como u_anderson anderson) select public.admin_alterar_acesso('u_alvo$r','aprovar',  null, '$v');"
  em_paralelo "$TMP/b2" "$(como u_pedro pedro)       select public.admin_alterar_acesso('u_alvo$r','rejeitar', null, '$v');"
  wait
  aceita "$TMP/b1" 'estado_mudou' "B$r/aprovar"; aceita "$TMP/b2" 'estado_mudou' "B$r/rejeitar"
  ev=$($Q -c "select count(*) from public.eventos_acesso where alvo_id='u_alvo$r' and acao in ('aprovou','rejeitou')")
  if [ "$ev" != 1 ]; then echo "FALHOU rodada $r: $ev ações registradas"; falhas=$((falhas + 1)); fi
done
echo "ok  B: aprovar x rejeitar simultâneos (15 rodadas): exatamente 1 vence"

# Cenário C: 4 membros copiando o mesmo código ao mesmo tempo -> exatamente 3 cópias.
for u in c1 c2 c3 c4; do
  $Q -c "insert into public.usuarios (id, nome, papel) values ('u_$u','$u','membro') on conflict (id) do update set papel='membro', situacao='ativo'"
done
for r in $(seq 1 15); do
  $Q -c "$(como u_anderson anderson) select public.postar_codigos('77', array['CONC$r']);" >/dev/null
  id=$($Q -c "select id from public.codigos where codigo='CONC$r'")
  for u in c1 c2 c3 c4; do em_paralelo "$TMP/c_$u" "$(como u_$u $u) select public.copiar_codigo($id);"; done
  wait
  for u in c1 c2 c3 c4; do aceita "$TMP/c_$u" '' "C$r/$u"; done   # nenhum erro é aceitável aqui
  n=$($Q -c "select count(*) from public.copias where codigo_id=$id")
  t=$(cat "$TMP"/c_c? | grep -c '^ok t$' || true)
  if [ "$n" != 3 ] || [ "$t" != 3 ]; then echo "FALHOU rodada $r: copias=$n true=$t"; falhas=$((falhas + 1)); fi
done
echo "ok  C: 4 cópias simultâneas (15 rodadas): sempre exatamente 3"

# Cenário D: membro sendo suspenso enquanto copia -> copia antes ou é negado.
for r in $(seq 1 10); do
  $Q -c "update public.usuarios set papel='membro', situacao='ativo' where id='u_c1'"
  $Q -c "$(como u_anderson anderson) select public.postar_codigos('BRA365', array['SUSP$r']);" >/dev/null
  id=$($Q -c "select id from public.codigos where codigo='SUSP$r'")
  em_paralelo "$TMP/d1" "$(como u_c1 c1) select public.copiar_codigo($id);"
  em_paralelo "$TMP/d2" "$(como u_anderson anderson) select public.admin_alterar_acesso('u_c1','suspender');"
  wait
  aceita "$TMP/d1" 'acesso_negado' "D$r/copia"
  aceita "$TMP/d2" '' "D$r/suspensão"                                 # a suspensão sempre deve funcionar
  if ! grep -qE '^ok t$|acesso_negado' "$TMP/d1"; then echo "FALHOU rodada $r: $(cat "$TMP/d1")"; falhas=$((falhas + 1)); fi
done
echo "ok  D: suspensão durante cópia (10 rodadas): copia ou nega, sem erro inesperado"

[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE CONCORRÊNCIA PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
