#!/usr/bin/env bash
# Concorrência da pegar_lote() da migração 003 (rodar depois do 09_distribuicao.sql,
# que cria os usuários f3_). Usa só a plataforma BRA365.
#
#   H  4 lotes simultâneos: mesmo resultado da execução em sequência (nada é pulado)
#   I  lote x cópia individual pela última vaga: exatamente um registra
#   J  clique duplo do mesmo membro: os dois lotes juntos levam tudo, sem repetir
#   K  regra estrita: código antigo ocupado por uma cópia individual -> o lote
#      ESPERA e leva o antigo (a 002 pularia para o mais novo do mesmo autor)
#   L  trava presa > 5 s: 'lote_ocupado', nenhuma cópia registrada; depois funciona
#   M  falha DEPOIS de inserir (trava no usuário durante o INSERT): nada fica gravado
#   N  carga mista (lotes + cópias individuais + apagar, em paralelo): nenhum
#      deadlock, nenhum erro inesperado, invariantes mantidas
#
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/10_concorrencia_hibrida.sh
set -euo pipefail
: "${PSQL:?defina PSQL}"
command -v jq >/dev/null || { echo "precisa do jq"; exit 1; }
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0
como() { echo "select teste.como('$1', '$1'); set role authenticated;"; }
falha() { echo "FALHOU $*"; falhas=$((falhas + 1)); }
agora_ms() { date +%s%3N; }

em_paralelo() {
  local arq=$1; shift
  ( if out=$($Q -c "$*" 2>&1); then printf '%s\n' "$out" | sed '/^$/d' | tail -n 1 > "$arq"
    else echo "ERRO $(printf '%s' "$out" | tr '\n' ' ')" > "$arq"; fi ) &
}
confere_lote() {  # arquivo dono rótulo  -> lista devolvida = gravada
  local j; j=$(cat "$1")
  [[ $j == ERRO* ]] && { falha "$3: $j"; return; }
  local reg lote lista banco
  reg=$(jq -r '.registrados' <<<"$j"); lote=$(jq -r '.lote_id // ""' <<<"$j")
  lista=$(jq -r '[.codigos[].codigo] | join(",")' <<<"$j")
  [ "$(jq '.codigos | length' <<<"$j")" = "$reg" ] || falha "$3: tamanho da lista != registrados"
  if [ "$reg" = 0 ]; then [ -z "$lote" ] || falha "$3: lote vazio com id"; return; fi
  banco=$($Q -c "select string_agg(c.codigo, ',' order by c.criado_em, c.id) from public.copias p
                 join public.codigos c on c.id = p.codigo_id where p.lote_id = '$lote' and p.usuario_id = '$2'")
  [ "$banco" = "$lista" ] || falha "$3: devolvido [$lista] != gravado [$banco]"
}
invariantes() {
  local mx dup
  mx=$($Q -c "select coalesce(max(n), 0) from (select count(*) n from public.copias p join public.codigos c on c.id = p.codigo_id
              where c.plataforma = 'BRA365' group by p.codigo_id) t")
  [ "$mx" -le 3 ] || falha "$1: código com $mx cópias"
  dup=$($Q -c "select count(*) from public.copias p join public.codigos c on c.id = p.codigo_id
               where c.plataforma = 'BRA365' and p.usuario_id = c.autor_id")
  [ "$dup" = 0 ] || falha "$1: autor copiou o próprio código"
}
total_copias() { $Q -c "select count(*) from public.copias p join public.codigos c on c.id = p.codigo_id where c.plataforma = 'BRA365'"; }
# n códigos de cada autor; o 1º de cada é o mais antigo
codigos() {  # prefixo n autor...
  local pre=$1 n=$2; shift 2
  local lista; lista=$(printf "'%s'," "$@"); lista=${lista%,}
  $Q -c "delete from public.codigos where plataforma = 'BRA365';
         insert into public.codigos (plataforma, codigo, autor_id, criado_em)
         select 'BRA365', '$pre' || replace(a, 'f3_', '') || g, a, now() - interval '10 hours' + (g || ' minutes')::interval + (o || ' seconds')::interval
           from unnest(array[$lista]) with ordinality u(a, o), generate_series(1, $n) g;" >/dev/null
}

# H
for r in $(seq 1 15); do
  codigos "H${r}_" 3 f3_cafe f3_panda          # 6 códigos x 3 vagas = 18; 4 pedem 5 = 20
  for u in f3_x1 f3_x2 f3_x3 f3_u; do em_paralelo "$TMP/h_$u" "$(como $u) select public.pegar_lote('BRA365', 5);"; done
  wait
  for u in f3_x1 f3_x2 f3_x3 f3_u; do confere_lote "$TMP/h_$u" "$u" "H$r/$u"; done
  invariantes "H$r"
  # quem recebeu menos que o pedido não pode ter deixado nada elegível para trás
  for u in f3_x1 f3_x2 f3_x3 f3_u; do
    [ "$(jq -r .registrados "$TMP/h_$u")" -lt 5 ] || continue
    sobra=$($Q -c "select count(*) from public.codigos c where c.plataforma = 'BRA365' and c.autor_id <> '$u'
                   and not exists (select 1 from public.copias x where x.codigo_id = c.id and x.usuario_id = '$u')
                   and (select count(*) from public.copias x where x.codigo_id = c.id) < 3")
    [ "$sobra" = 0 ] || falha "H$r/$u: recebeu menos que 5 mas ainda há $sobra elegível(is)"
  done
  # resultado igual ao de rodar um depois do outro: 5 + 5 + 5 + 1 (os 3 primeiros
  # levam os mesmos 5 mais antigos, que esgotam; sobra 1 código para o último)
  [ "$(total_copias)" = 16 ] || falha "H$r: $(total_copias) cópias; esperado 16 (igual à execução em sequência)"
  [ "$(cat "$TMP"/h_* | jq -s -c 'map(.registrados) | sort')" = "[1,5,5,5]" ] || falha "H$r: distribuição $(cat "$TMP"/h_* | jq -s -c 'map(.registrados)')"
done
echo "ok  H: 4 lotes simultâneos (15 rodadas): mesmo resultado da execução em sequência (5,5,5,1); ninguém fica sem o que era elegível"

# I
for r in $(seq 1 15); do
  codigos "I${r}_" 1 f3_cafe
  $Q -c "insert into public.copias (codigo_id, usuario_id) select id, u from public.codigos, unnest(array['f3_x1','f3_x2']) u where plataforma = 'BRA365'" >/dev/null
  id=$($Q -c "select id from public.codigos where plataforma = 'BRA365'")
  em_paralelo "$TMP/i_lote" "$(como f3_u) select public.pegar_lote('BRA365', 1);"
  em_paralelo "$TMP/i_ind"  "$(como f3_x3) select public.copiar_codigo_v2($id);"
  wait
  confere_lote "$TMP/i_lote" f3_u "I$r/lote"
  ind=$(cat "$TMP/i_ind"); [[ $ind == ERRO* ]] && falha "I$r/individual: $ind"
  ganhou=$(jq -r '.registrados' "$TMP/i_lote"); st=$(jq -r '.status' <<<"$ind")
  [ "$($Q -c "select count(*) from public.copias where codigo_id = $id")" = 3 ] || falha "I$r: não terminou com 3 cópias"
  if [ "$ganhou" = 1 ]; then [ "$st" = esgotado ] || falha "I$r: lote venceu, individual disse $st"
  else [ "$st" = registrado ] || falha "I$r: lote perdeu, individual disse $st"; fi
done
echo "ok  I: lote x individual pela última vaga (15 rodadas): exatamente 1 registra, o outro é informado"

# J
for r in $(seq 1 15); do
  codigos "J${r}_" 3 f3_cafe f3_panda
  em_paralelo "$TMP/j1" "$(como f3_u) select public.pegar_lote('BRA365', 4);"
  em_paralelo "$TMP/j2" "$(como f3_u) select public.pegar_lote('BRA365', 4);"
  wait
  confere_lote "$TMP/j1" f3_u "J$r/1"; confere_lote "$TMP/j2" f3_u "J$r/2"
  comuns=$(jq -s '[.[0].codigos[].codigo] - ([.[0].codigos[].codigo] - [.[1].codigos[].codigo]) | length' "$TMP/j1" "$TMP/j2")
  [ "$comuns" = 0 ] || falha "J$r: $comuns código(s) repetidos"
  soma=$(jq -s 'map(.registrados) | add' "$TMP/j1" "$TMP/j2")
  [ "$soma" = 6 ] || falha "J$r: $soma registrados; esperado exatamente 6"
  # um dos dois lotes é o primeiro: 4 = 2 de cada autor, os dois mais antigos de cada
  primeiro=$(jq -s -r 'map(select(.registrados == 4))[0] | [.codigos[].codigo] | sort | join(",")' "$TMP/j1" "$TMP/j2")
  [ "$primeiro" = "J${r}_cafe1,J${r}_cafe2,J${r}_panda1,J${r}_panda2" ] || falha "J$r: primeiro lote [$primeiro]"
  invariantes "J$r"
done
echo "ok  J: clique duplo (15 rodadas): 4 + 2, sem repetir; o primeiro leva os 2 mais antigos de cada autor"

# K
for r in $(seq 1 5); do
  codigos "K${r}_" 3 f3_cafe
  antigo=$($Q -c "select id from public.codigos where plataforma = 'BRA365' and codigo = 'K${r}_cafe1'")
  # cópia individual de f3_x1 no código mais antigo, segurando a transação 2 s
  ( $Q -c "begin; $(como f3_x1) select public.copiar_codigo_v2($antigo); select pg_sleep(2); commit;" >/dev/null 2>"$TMP/k_ind" ) &
  sleep 0.5
  t0=$(agora_ms)
  em_paralelo "$TMP/k_lote" "$(como f3_u) select public.pegar_lote('BRA365', 1);"
  wait
  dt=$(( $(agora_ms) - t0 ))
  [ -s "$TMP/k_ind" ] && falha "K$r: cópia individual deu erro: $(cat "$TMP/k_ind")"
  confere_lote "$TMP/k_lote" f3_u "K$r"
  got=$(jq -r '[.codigos[].codigo] | join(",")' "$TMP/k_lote")
  [ "$got" = "K${r}_cafe1" ] || falha "K$r: lote levou [$got]; esperado o mais antigo K${r}_cafe1"
  [ "$dt" -ge 1000 ] || falha "K$r: o lote não esperou (${dt} ms)"
done
echo "ok  K: código mais antigo ocupado: o lote espera (~1,5 s) e leva o mais antigo, não pula para o mais novo"

# L
codigos "L_" 2 f3_cafe
alvo=$($Q -c "select id from public.codigos where plataforma = 'BRA365' and codigo = 'L_cafe2'")
( $Q -c "begin; select 1 from public.codigos where id = $alvo for update; select pg_sleep(7); commit;" >/dev/null ) &
sleep 0.5
antes=$(total_copias); t0=$(agora_ms)
em_paralelo "$TMP/l_lote" "$(como f3_u) select public.pegar_lote('BRA365', 2);"
while [ ! -s "$TMP/l_lote" ]; do sleep 0.1; done
dt=$(( $(agora_ms) - t0 ))
grep -q "lote_ocupado" "$TMP/l_lote" || falha "L: esperava lote_ocupado, veio $(cat "$TMP/l_lote")"
[ "$dt" -ge 4500 ] && [ "$dt" -le 6500 ] || falha "L: tempo até o erro ${dt} ms (esperado ~5000)"
[ "$(total_copias)" = "$antes" ] || falha "L: o lote recusado registrou cópias"
wait
r=$($Q -c "$(como f3_u) select public.pegar_lote('BRA365', 2);" | tail -n 1)
[ "$(jq -r .registrados <<<"$r")" = 2 ] || falha "L: depois de liberar, esperava 2 registrados: $r"
echo "ok  L: trava presa 7 s -> 'lote_ocupado' em ${dt} ms, nenhuma cópia; depois de liberar, o lote sai inteiro"

# M
codigos "M_" 3 f3_cafe f3_panda
( $Q -c "begin; select 1 from public.usuarios where id = 'f3_u' for update; select pg_sleep(7); commit;" >/dev/null ) &
sleep 0.5
antes=$(total_copias)
r=$($Q -c "$(como f3_u) select public.pegar_lote('BRA365', 6);" 2>&1 | tr '\n' ' ' || true)
[[ $r == *lote_ocupado* ]] || falha "M: esperava lote_ocupado, veio $r"
[ "$(total_copias)" = "$antes" ] || falha "M: falha no INSERT deixou $(( $(total_copias) - antes )) cópia(s) parciais"
wait
echo "ok  M: falha durante o INSERT (6 linhas): nenhuma cópia parcial gravada"

# N
for r in $(seq 1 10); do
  codigos "N${r}_" 4 f3_cafe f3_panda f3_joao f3_anderson
  ids=($($Q -c "select id from public.codigos where plataforma = 'BRA365' order by random()"))
  k=0
  for u in f3_x1 f3_x2 f3_x3 f3_u f3_v; do
    em_paralelo "$TMP/n_l_$u" "$(como $u) select public.pegar_lote('BRA365', $((3 + RANDOM % 8)));"
    em_paralelo "$TMP/n_i_$u" "$(como $u) select public.copiar_codigo_v2(${ids[$k]});"
    em_paralelo "$TMP/n_o_$u" "$(como $u) select public.copiar_codigo(${ids[$((k + 1))]});"
    k=$((k + 2))
  done
  em_paralelo "$TMP/n_apaga" "$(como f3_cafe) select public.apagar_codigo(${ids[15]});"
  wait
  if grep -l "ERRO" "$TMP"/n_* >/dev/null 2>&1; then falha "N$r: $(grep -h ERRO "$TMP"/n_* | head -n 2)"; fi
  for u in f3_x1 f3_x2 f3_x3 f3_u f3_v; do confere_lote "$TMP/n_l_$u" "$u" "N$r/$u"; done
  invariantes "N$r"
done
echo "ok  N: carga mista (10 rodadas x 16 operações paralelas): nenhum deadlock nem erro, invariantes mantidas"

$Q -c "delete from public.codigos where plataforma = 'BRA365'" >/dev/null
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE CONCORRÊNCIA DA 003 PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
