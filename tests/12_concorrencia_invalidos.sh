#!/usr/bin/env bash
# Concorrência da migração 004 (rodar depois do 11_invalidos.sql, que cria os
# usuários f4_). Usa só a plataforma 77.
#
#   P  2 relatos qualificados SIMULTÂNEOS no mesmo código: suspende uma vez só
#   Q  relato que suspende x cópia individual x lote, ao mesmo tempo: respostas
#      coerentes com o que ficou gravado; nunca mais de 3 cópias
#   R  admin confirma x alguém republica a mesma combinação (já vencida):
#      nunca sobra publicação ativa de um código bloqueado
#   S  carga mista (relatos de vários códigos, lotes, cópias, confirmações,
#      reversões, apagar): nenhum impasse (deadlock) nem erro inesperado
#
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/12_concorrencia_invalidos.sh
set -euo pipefail
: "${PSQL:?defina PSQL}"
command -v jq >/dev/null || { echo "precisa do jq"; exit 1; }
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0
como() { echo "select teste.como('$1', '$1'); set role authenticated;"; }
falha() { echo "FALHOU $*"; falhas=$((falhas + 1)); }
em_paralelo() {
  local arq=$1; shift
  ( if out=$($Q -c "$*" 2>&1); then printf '%s\n' "$out" | sed '/^$/d' | tail -n 1 > "$arq"
    else echo "ERRO $(printf '%s' "$out" | tr '\n' ' ')" > "$arq"; fi ) &
}
id_de() { $Q -c "select max(id) from public.codigos where plataforma = '77' and codigo = '$1'"; }
limpa() { $Q -c "delete from public.codigos where plataforma = '77'; delete from public.codigos_bloqueados where plataforma = '77';" >/dev/null; }
max_copias() { $Q -c "select coalesce(max(n), 0) from (select count(*) n from public.copias p join public.codigos c on c.id = p.codigo_id where c.plataforma = '77' group by p.codigo_id) t"; }

# P
for r in $(seq 1 15); do
  limpa
  $Q -c "insert into public.codigos (plataforma, codigo, autor_id) values ('77', 'P$r', 'f4_a')" >/dev/null
  id=$(id_de "P$r")
  $Q -c "insert into public.copias (codigo_id, usuario_id) values ($id, 'f4_b'), ($id, 'f4_c')" >/dev/null
  em_paralelo "$TMP/p_b" "$(como f4_b) select public.relatar_invalidos('77', array['P$r']);"
  em_paralelo "$TMP/p_c" "$(como f4_c) select public.relatar_invalidos('77', array['P$r']);"
  wait
  for f in p_b p_c; do [[ $(cat "$TMP/$f") == ERRO* ]] && falha "P$r/$f: $(cat "$TMP/$f")"; done
  susp=$(jq -s 'map(.suspensos_agora) | add' "$TMP/p_b" "$TMP/p_c")
  ev=$($Q -c "select count(*) from public.eventos_invalidos where codigo_id = $id and acao = 'suspenso_automatico'")
  st=$($Q -c "select desativacao from public.codigos where id = $id")
  [ "$susp" = 1 ] && [ "$ev" = 1 ] && [ "$st" = relatos ] || falha "P$r: suspensos=$susp eventos=$ev estado=$st"
done
echo "ok  P: 2 relatos qualificados simultâneos (15 rodadas): suspenso exatamente uma vez"

# Q
for r in $(seq 1 20); do
  limpa
  $Q -c "insert into public.codigos (plataforma, codigo, autor_id) select '77', 'Q${r}_' || g, 'f4_a' from generate_series(1, 3) g" >/dev/null
  id=$(id_de "Q${r}_1")
  $Q -c "insert into public.copias (codigo_id, usuario_id) values ($id, 'f4_b');
         insert into public.relatos_invalidos (codigo_id, plataforma, codigo, usuario_id, qualificado) values ($id, '77', 'Q${r}_1', 'f4_b', true);
         insert into public.copias (codigo_id, usuario_id) values ($id, 'f4_c')" >/dev/null
  em_paralelo "$TMP/q_rel"  "$(como f4_c) select public.relatar_invalidos('77', array['Q${r}_1']);"
  em_paralelo "$TMP/q_ind"  "$(como f4_d) select public.copiar_codigo_v2($id);"
  em_paralelo "$TMP/q_lote" "$(como f4_adm) select public.pegar_lote('77', 3);"
  wait
  for f in q_rel q_ind q_lote; do [[ $(cat "$TMP/$f") == ERRO* ]] && falha "Q$r/$f: $(cat "$TMP/$f")"; done
  [ "$(jq -r .suspensos_agora "$TMP/q_rel")" = 1 ] || falha "Q$r: relato não suspendeu"
  st=$(jq -r .status "$TMP/q_ind"); tem_d=$($Q -c "select count(*) from public.copias where codigo_id = $id and usuario_id = 'f4_d'")
  case "$st" in registrado) [ "$tem_d" = 1 ] || falha "Q$r: registrado sem cópia";;
                invalidado|esgotado) [ "$tem_d" = 0 ] || falha "Q$r: $st mas copiou";;   # esgotado: o lote levou a 3ª vaga antes
                *) falha "Q$r: status inesperado $st";; esac
  no_lote=$(jq -r "[.codigos[].id] | index($id) != null" "$TMP/q_lote"); tem_adm=$($Q -c "select count(*) from public.copias where codigo_id = $id and usuario_id = 'f4_adm'")
  if ! { [ "$no_lote" = true ] && [ "$tem_adm" = 1 ]; } && ! { [ "$no_lote" = false ] && [ "$tem_adm" = 0 ]; }; then
    falha "Q$r: lote incoerente ($no_lote/$tem_adm)"; fi
  [ "$(max_copias)" -le 3 ] || falha "Q$r: código com mais de 3 cópias"
  echo "$st/$no_lote" >> "$TMP/q_resumo"
done
echo "ok  Q: relato que suspende x cópia x lote (20 rodadas): respostas iguais ao gravado, ≤ 3 cópias ($(sort "$TMP/q_resumo" | uniq -c | tr -s ' ' | tr '\n' ';'))"

# R
for r in $(seq 1 15); do
  limpa
  $Q -c "insert into public.codigos (plataforma, codigo, autor_id, criado_em) values ('77', 'R$r', 'f4_a', now() - interval '49 hours')" >/dev/null
  em_paralelo "$TMP/r_conf" "$(como f4_adm) select public.admin_confirmar_invalido('77', 'R$r');"
  em_paralelo "$TMP/r_post" "$(como f4_b) select public.postar_codigos('77', array['R$r']);"
  wait
  for f in r_conf r_post; do [[ $(cat "$TMP/$f") == ERRO* ]] && falha "R$r/$f: $(cat "$TMP/$f")"; done
  ativos=$($Q -c "select count(*) from public.codigos where plataforma = '77' and codigo = 'R$r' and desativado_em is null")
  [ "$ativos" = 0 ] || falha "R$r: sobrou publicação ativa de código bloqueado"
  echo "$(jq -c '{a: .adicionados, b: (.bloqueados | length)}' "$TMP/r_post")" >> "$TMP/r_resumo"
done
echo "ok  R: confirmação x republicação (15 rodadas): nenhuma publicação ativa sobra ($(sort "$TMP/r_resumo" | uniq -c | tr -s ' ' | tr '\n' ';'))"

# S
for r in $(seq 1 10); do
  limpa
  $Q -c "insert into public.codigos (plataforma, codigo, autor_id) select '77', 'S${r}_' || g, (array['f4_a','f4_b','f4_c'])[1 + g % 3] from generate_series(1, 30) g;
         insert into public.copias (codigo_id, usuario_id) select c.id, u from public.codigos c, unnest(array['f4_b','f4_c','f4_d']) u
          where c.plataforma = '77' and c.autor_id <> u and random() < 0.4" >/dev/null
  lista=$(seq 1 30 | sort -R | head -n 20 | sed "s/^/'S${r}_/;s/$/'/" | paste -sd,)
  lista2=$(seq 1 30 | sort -R | head -n 20 | sed "s/^/'S${r}_/;s/$/'/" | paste -sd,)
  em_paralelo "$TMP/s1" "$(como f4_b) select public.relatar_invalidos('77', array[$lista]);"
  em_paralelo "$TMP/s2" "$(como f4_c) select public.relatar_invalidos('77', array[$lista2]);"
  em_paralelo "$TMP/s3" "$(como f4_d) select public.relatar_invalidos('77', array[$lista]);"
  em_paralelo "$TMP/s4" "$(como f4_adm) select public.pegar_lote('77', 15);"
  em_paralelo "$TMP/s5" "$(como f4_d) select public.pegar_lote('77', 10);"
  em_paralelo "$TMP/s6" "$(como f4_adm) select public.admin_confirmar_invalido('77', 'S${r}_7');"
  em_paralelo "$TMP/s7" "$(como f4_adm) select public.admin_reverter_invalido('77', 'S${r}_8');"
  em_paralelo "$TMP/s8" "$(como f4_b) select public.copiar_codigo_v2($(id_de "S${r}_9"));"
  em_paralelo "$TMP/s9" "$(como f4_a) select public.apagar_codigo($(id_de "S${r}_3"));"
  em_paralelo "$TMP/s10" "$(como f4_c) select public.postar_codigos('77', array['S${r}_7', 'S${r}_NOVO']);"
  wait
  if grep -l "ERRO" "$TMP"/s[0-9]* >/dev/null 2>&1; then falha "S$r: $(grep -h ERRO "$TMP"/s[0-9]* | head -n 2)"; fi
  [ "$(max_copias)" -le 3 ] || falha "S$r: código com mais de 3 cópias"
  inc=$($Q -c "select count(*) from public.codigos where plataforma = '77' and (desativado_em is null) <> (desativacao is null)")
  [ "$inc" = 0 ] || falha "S$r: estado de desativação incoerente"
done
echo "ok  S: carga mista (10 rodadas x 10 operações paralelas): nenhum impasse nem erro, ≤ 3 cópias"

limpa
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE CONCORRÊNCIA DA 004 PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
