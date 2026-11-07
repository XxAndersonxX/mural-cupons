#!/usr/bin/env bash
# Concorrência da cópia em lote (depois da 002 e do 06_copias.sql).
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/07_concorrencia_lote.sh
set -euo pipefail
: "${PSQL:?defina PSQL}"
command -v jq >/dev/null || { echo "precisa do jq"; exit 1; }
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0
como() { echo "select teste.como('$1', '$1'); set role authenticated;"; }
falha() { echo "FALHOU $*"; falhas=$((falhas + 1)); }

# roda em segundo plano; guarda a última linha (o JSON) ou o erro
em_paralelo() {
  local arq=$1; shift
  ( if out=$($Q -c "$*" 2>&1); then printf '%s\n' "$out" | sed '/^$/d' | tail -n 1 > "$arq"
    else echo "ERRO $(printf '%s' "$out" | tr '\n' ' ')" > "$arq"; fi ) &
}
# o lote devolvido tem que bater EXATAMENTE com o que ficou gravado no banco
confere_lote() {  # arquivo dono rótulo
  local j; j=$(cat "$1")
  [[ $j == ERRO* ]] && { falha "$3: $j"; return; }
  local reg lote lista
  reg=$(jq -r '.registrados' <<<"$j"); lote=$(jq -r '.lote_id // ""' <<<"$j")
  lista=$(jq -r '[.codigos[].codigo] | join(",")' <<<"$j")
  [ "$(jq '.codigos | length' <<<"$j")" = "$reg" ] || falha "$3: tamanho da lista != registrados"
  if [ "$reg" = 0 ]; then [ -z "$lote" ] || falha "$3: lote sem registros com id"; return; fi
  local banco; banco=$($Q -c "select string_agg(c.codigo, ',' order by c.criado_em, c.id) from public.copias p
                              join public.codigos c on c.id = p.codigo_id where p.lote_id = '$lote' and p.usuario_id = '$2'")
  [ "$banco" = "$lista" ] || falha "$3: devolvido [$lista] != gravado [$banco]"
}
invariantes() {  # rótulo
  local mx dup
  mx=$($Q -c "select coalesce(max(n), 0) from (select count(*) n from public.copias p join public.codigos c on c.id = p.codigo_id
              where c.plataforma = 'Sorte25' group by p.codigo_id) t")
  [ "$mx" -le 3 ] || falha "$1: código com $mx cópias"
  dup=$($Q -c "select count(*) from public.copias p join public.codigos c on c.id = p.codigo_id
               where c.plataforma = 'Sorte25' and p.usuario_id = c.autor_id")
  [ "$dup" = 0 ] || falha "$1: autor copiou o próprio código"
}
novos_codigos() {  # quantidade prefixo
  $Q -c "delete from public.codigos where plataforma = 'Sorte25';
         insert into public.codigos (plataforma, codigo, autor_id, criado_em)
         select 'Sorte25', '$2' || g, 'f2_autor', now() - (g || ' minutes')::interval from generate_series(1, $1) g;" >/dev/null
}

# E: 4 membros pedem lote de 5 ao mesmo tempo, com 5 códigos (capacidade 15)
for r in $(seq 1 15); do
  novos_codigos 5 "E${r}_"
  for u in f2_a f2_b f2_c f2_d; do em_paralelo "$TMP/e_$u" "$(como $u) select public.pegar_lote('Sorte25', 5);"; done
  wait
  for u in f2_a f2_b f2_c f2_d; do confere_lote "$TMP/e_$u" "$u" "E$r/$u"; done
  invariantes "E$r"
  tot=$($Q -c "select count(*) from public.copias p join public.codigos c on c.id = p.codigo_id where c.plataforma = 'Sorte25'")
  soma=$(cat "$TMP"/e_f2_? | jq -s 'map(.registrados) | add')
  [ "$tot" = "$soma" ] || falha "E$r: banco tem $tot cópias, lotes devolveram $soma"
done
echo "ok  E: 4 lotes simultâneos (15 rodadas): nenhum código > 3, cada lista = o que foi gravado"

# F: lote x cópia individual disputando a ÚLTIMA vaga de um código
for r in $(seq 1 15); do
  novos_codigos 1 "F${r}_"
  $Q -c "insert into public.copias (codigo_id, usuario_id) select id, u from public.codigos, unnest(array['f2_c','f2_d']) u where plataforma = 'Sorte25'" >/dev/null
  id=$($Q -c "select id from public.codigos where plataforma = 'Sorte25'")
  em_paralelo "$TMP/f_lote" "$(como f2_a) select public.pegar_lote('Sorte25', 1);"
  em_paralelo "$TMP/f_ind"  "$(como f2_b) select public.copiar_codigo_v2($id);"
  wait
  confere_lote "$TMP/f_lote" f2_a "F$r/lote"
  ind=$(cat "$TMP/f_ind"); [[ $ind == ERRO* ]] && falha "F$r/individual: $ind"
  ganhou_lote=$(jq -r '.registrados' "$TMP/f_lote"); st=$(jq -r '.status' <<<"$ind")
  n=$($Q -c "select count(*) from public.copias where codigo_id = $id")
  [ "$n" = 3 ] || falha "F$r: $n cópias (esperado 3)"
  if [ "$ganhou_lote" = 1 ]; then [ "$st" = esgotado ] || falha "F$r: lote venceu mas individual disse $st"
  else [ "$st" = registrado ] || falha "F$r: lote perdeu (0) e individual disse $st"; fi
done
echo "ok  F: lote x individual pela última vaga (15 rodadas): exatamente 1 registra, o outro é informado"

# G: o mesmo membro clica duas vezes (dois lotes ao mesmo tempo)
for r in $(seq 1 15); do
  novos_codigos 6 "G${r}_"
  em_paralelo "$TMP/g1" "$(como f2_a) select public.pegar_lote('Sorte25', 4);"
  em_paralelo "$TMP/g2" "$(como f2_a) select public.pegar_lote('Sorte25', 4);"
  wait
  confere_lote "$TMP/g1" f2_a "G$r/1"; confere_lote "$TMP/g2" f2_a "G$r/2"
  comuns=$(jq -s '(.[0].codigos | map(.codigo)) - ((.[0].codigos | map(.codigo)) - (.[1].codigos | map(.codigo))) | length' "$TMP/g1" "$TMP/g2")
  [ "$comuns" = 0 ] || falha "G$r: $comuns código(s) nos dois lotes"
  soma=$(jq -s 'map(.registrados) | add' "$TMP/g1" "$TMP/g2")
  [ "$soma" = 6 ] || [ "$soma" -le 6 ] || falha "G$r: $soma registrados para 6 códigos"
  invariantes "G$r"
done
echo "ok  G: clique duplo (15 rodadas): os dois lotes nunca repetem código"

$Q -c "delete from public.codigos where plataforma = 'Sorte25'" >/dev/null
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE CONCORRÊNCIA DO LOTE PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
