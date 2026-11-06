#!/usr/bin/env bash
# Testes de concorrência (precisam de várias conexões ao mesmo tempo).
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/03_concorrencia.sh
set -euo pipefail
: "${PSQL:?defina PSQL}"
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
falhas=0

como() { echo "select teste.como('$1', '$2'); set role authenticated;"; }

# Cenário A: dois admins removendo o admin do outro ao mesmo tempo.
# Esperado: sempre sobra pelo menos 1 admin ativo.
for r in $(seq 1 15); do
  $Q -c "update public.usuarios set papel='admin', situacao='ativo' where id in ('u_anderson','u_pedro')"
  ( $Q -c "$(como u_anderson anderson) select public.admin_alterar_acesso('u_pedro','remover_admin');" >/dev/null 2>&1 || true ) &
  ( $Q -c "$(como u_pedro pedro) select public.admin_alterar_acesso('u_anderson','remover_admin');" >/dev/null 2>&1 || true ) &
  wait
  n=$($Q -c "select count(*) from public.usuarios where papel='admin' and situacao='ativo'")
  if [ "$n" -lt 1 ]; then echo "FALHOU rodada $r: ficou sem admin"; falhas=$((falhas+1)); fi
done
echo "ok  A: dois admins removendo um ao outro (15 rodadas) sempre deixam >= 1 admin"

# Cenário B: dois admins agindo sobre o mesmo pendente (aprovar x rejeitar).
# Esperado: exatamente uma ação vence e é auditada.
$Q -c "update public.usuarios set papel='admin', situacao='ativo' where id in ('u_anderson','u_pedro')"
for r in $(seq 1 15); do
  $Q -c "insert into public.usuarios (id, nome) values ('u_alvo$r','alvo$r')"
  v=$($Q -c "select atualizado_em from public.usuarios where id='u_alvo$r'")   # o que os dois admins viram na tela
  ( $Q -c "$(como u_anderson anderson) select public.admin_alterar_acesso('u_alvo$r','aprovar',  null, '$v');" >/dev/null 2>&1 || true ) &
  ( $Q -c "$(como u_pedro pedro)       select public.admin_alterar_acesso('u_alvo$r','rejeitar', null, '$v');" >/dev/null 2>&1 || true ) &
  wait
  ev=$($Q -c "select count(*) from public.eventos_acesso where alvo_id='u_alvo$r' and acao in ('aprovou','rejeitou')")
  if [ "$ev" != 1 ]; then echo "FALHOU rodada $r: $ev ações registradas"; falhas=$((falhas+1)); fi
done
echo "ok  B: aprovar x rejeitar simultâneos (15 rodadas): exatamente 1 vence"

# Cenário C: 4 membros copiando o mesmo código ao mesmo tempo -> exatamente 3 cópias.
for u in c1 c2 c3 c4; do
  $Q -c "insert into public.usuarios (id, nome, papel) values ('u_$u','$u','membro') on conflict (id) do nothing"
done
for r in $(seq 1 15); do
  $Q -c "$(como u_anderson anderson) select public.postar_codigos('77', array['CONC$r']);" >/dev/null
  id=$($Q -c "select id from public.codigos where codigo='CONC$r'")
  for u in c1 c2 c3 c4; do
    ( $Q -c "$(como u_$u $u) select public.copiar_codigo($id);" > "$TMP/$u" 2>&1 || true ) &
  done
  wait
  n=$($Q -c "select count(*) from public.copias where codigo_id=$id")
  t=$(cat "$TMP"/c? | grep -c '^t$' || true)
  if [ "$n" != 3 ] || [ "$t" != 3 ]; then echo "FALHOU rodada $r: copias=$n true=$t"; falhas=$((falhas+1)); fi
done
echo "ok  C: 4 cópias simultâneas (15 rodadas): sempre exatamente 3"

# Cenário D: membro sendo suspenso enquanto copia -> ou copia antes, ou é negado. Nunca erro estranho.
$Q -c "update public.usuarios set papel='membro', situacao='ativo' where id='u_c1'"
for r in $(seq 1 10); do
  $Q -c "update public.usuarios set situacao='ativo' where id='u_c1'"
  $Q -c "$(como u_anderson anderson) select public.postar_codigos('BRA365', array['SUSP$r']);" >/dev/null
  id=$($Q -c "select id from public.codigos where codigo='SUSP$r'")
  ( $Q -c "$(como u_c1 c1) select public.copiar_codigo($id);" > "$TMP/d" 2>&1 || true ) &
  ( $Q -c "$(como u_anderson anderson) select public.admin_alterar_acesso('u_c1','suspender');" >/dev/null 2>&1 || true ) &
  wait
  if ! grep -qE '^t$|acesso_negado' "$TMP/d"; then echo "FALHOU rodada $r: $(cat "$TMP/d")"; falhas=$((falhas+1)); fi
done
echo "ok  D: suspensão durante cópia (10 rodadas): copia ou nega, sem erro inesperado"

rm -rf "$TMP"
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE CONCORRÊNCIA PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
