#!/usr/bin/env bash
# Concorrência de apagar_codigo() x cópias (migração 005). DETERMINÍSTICO:
# a transação "A" segura a trava e dorme; o teste só segue quando o banco
# confirma (pg_stat_activity) que A está dormindo com a trava e que B está
# ESPERANDO por ela (wait_event_type = 'Lock'). Nada depende de sorte.
#
#   1  cópia trava primeiro (v2, v1 e lote) -> exclusão espera e devolve false;
#      código e cópia continuam
#   2  exclusão trava primeiro -> cópia espera e recebe 'inexistente' / false /
#      lote sem o código; nenhuma cópia órfã
#   3  duas exclusões simultâneas do autor -> exatamente uma apaga
#   4  quem não é o autor -> false, sem travar a linha de ninguém
#   5  código com cópias anteriores -> false
#   6  carga mista em paralelo -> nenhum impasse; toda cópia confirmada existe
#
# Uso: PSQL="psql -h HOST -p PORTA -U postgres -d BANCO" ./tests/13_apagar_concorrencia.sh
#      (banco com 001 e a 005; cria os usuários f5_ e usa a plataforma Sorte25)
set -euo pipefail
: "${PSQL:?defina PSQL}"
command -v jq >/dev/null || { echo "precisa do jq"; exit 1; }
Q="$PSQL -q -X -A -t -v ON_ERROR_STOP=1"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
falhas=0
falha() { echo "FALHOU $*"; falhas=$((falhas + 1)); }
ini=0
fim_secao() { if [ "$falhas" = "$ini" ]; then echo "ok  $*"; else echo "XX  seção com falhas: ${*%%:*}"; fi; ini=$falhas; }
como() { echo "select teste.como('$1', '$1'); set role authenticated;"; }

$Q >/dev/null <<'SQL'
insert into public.usuarios (id, nome, papel, situacao) values
  ('f5_autor', 'f5autor', 'membro', 'ativo'), ('f5_b', 'f5b', 'membro', 'ativo'),
  ('f5_c', 'f5c', 'membro', 'ativo'), ('f5_d', 'f5d', 'membro', 'ativo')
on conflict (id) do nothing;
SQL
# o que existe neste banco (a 005 só exige a 001; v2 e lote vêm da 002/003)
VIAS="v1"
[ "$($Q -c "select to_regproc('public.copiar_codigo_v2') is not null")" = t ] && VIAS="v2 v1"
[ "$($Q -c "select to_regproc('public.pegar_lote') is not null")" = t ] && VIAS="$VIAS lote"
# 002: o lote PULA código travado (SKIP LOCKED) em vez de esperar; 003+: espera
LOTE_PULA=$($Q -c "select coalesce((select prosrc ilike '%skip locked%' from pg_proc where proname = 'pegar_lote'), false)")
echo "== caminhos de cópia neste banco: $VIAS$( [ "$LOTE_PULA" = t ] && echo ' (lote da 002: pula travados)')"

novo_codigo() {  # cria um código do f5_autor (plataforma Sorte25, só ele) e devolve o id
  $Q -c "delete from public.codigos where plataforma = 'Sorte25';
         insert into public.codigos (plataforma, codigo, autor_id) values ('Sorte25', '$1', 'f5_autor') returning id" | tail -n 1
}
existe() { $Q -c "select count(*) from public.codigos where id = $1"; }
copias_de() { $Q -c "select count(*) from public.copias where codigo_id = $1"; }

# A: transação que roda $2 e depois dorme $3 s segurando o que travou
segura() {
  ( PGAPPNAME=$1 $Q -c "begin; $2; select pg_sleep($3); commit;" > "$TMP/$1.out" 2>&1 || echo "ERRO $(cat "$TMP/$1.out")" > "$TMP/$1.out" ) &
}
# B: chamada que deve ficar esperando a trava de A
chama() {
  ( PGAPPNAME=$1 $Q -c "$2" > "$TMP/$1.out" 2>&1 || echo "ERRO $(cat "$TMP/$1.out")" > "$TMP/$1.out" ) &
}
espera() {  # app condição -> espera até o banco confirmar
  local i
  for i in $(seq 1 200); do
    [ "$($Q -c "select count(*) from pg_stat_activity where application_name = '$1' and $2")" -ge 1 ] && return 0
    sleep 0.05
  done
  return 1
}
resultado() { grep -v '^$' "$TMP/$1.out" | tail -n 1; }

# ---------- 1. cópia trava primeiro ----------
for via in $VIAS; do
  id=$(novo_codigo "C1_$via")
  case $via in
    v2)   sql_copia="select public.copiar_codigo_v2($id)" ;;
    v1)   sql_copia="select public.copiar_codigo($id)" ;;
    lote) sql_copia="select public.pegar_lote('Sorte25', 5)" ;;
  esac
  segura A "$(como f5_b) $sql_copia" 2
  espera A "wait_event = 'PgSleep'" || falha "1/$via: A não chegou a segurar a trava"
  chama B "$(como f5_autor) select public.apagar_codigo($id);"
  espera B "wait_event_type = 'Lock'" || falha "1/$via: a exclusão não ficou esperando a trava da cópia"
  wait
  [ "$(resultado B)" = f ] || falha "1/$via: exclusão devolveu '$(resultado B)' (esperado f)"
  [ "$(existe "$id")" = 1 ] && [ "$(copias_de "$id")" = 1 ] || falha "1/$via: código=$(existe "$id") cópias=$(copias_de "$id") (esperado 1 e 1)"
  case $via in
    v2) [ "$(resultado A | jq -r .status)" = registrado ] || falha "1/$via: cópia devolveu $(resultado A)" ;;
    v1) [ "$(resultado A)" = t ] || falha "1/$via: cópia devolveu $(resultado A)" ;;
    lote) [ "$(resultado A | jq -r .registrados)" = 1 ] || falha "1/$via: lote devolveu $(resultado A)" ;;
  esac
done
fim_secao "1. cópia trava primeiro (cópia individual v2, v1 e lote): a exclusão espera, devolve false; código e cópia confirmada intactos"

# ---------- 2. exclusão trava primeiro ----------
for via in $VIAS; do
  id=$(novo_codigo "C2_$via")
  case $via in
    v2)   sql_copia="select public.copiar_codigo_v2($id)" ;;
    v1)   sql_copia="select public.copiar_codigo($id)" ;;
    lote) sql_copia="select public.pegar_lote('Sorte25', 5)" ;;
  esac
  segura A "$(como f5_autor) select public.apagar_codigo($id)" 2
  espera A "wait_event = 'PgSleep'" || falha "2/$via: A não chegou a segurar a trava"
  chama B "$(como f5_b) $sql_copia;"
  if [ "$via" = lote ] && [ "$LOTE_PULA" = t ]; then :   # 002: pula o travado (não espera)
  else espera B "wait_event_type = 'Lock'" || falha "2/$via: a cópia não ficou esperando a trava da exclusão"; fi
  wait
  [ "$(grep -v '^$' "$TMP/A.out" | head -n 1)" = t ] || falha "2/$via: exclusão devolveu $(cat "$TMP/A.out")"
  [ "$(existe "$id")" = 0 ] || falha "2/$via: código não foi apagado"
  [ "$($Q -c "select count(*) from public.copias where usuario_id = 'f5_b' and codigo_id = $id")" = 0 ] || falha "2/$via: sobrou cópia"
  case $via in
    v2) [ "$(resultado B | jq -r .status)" = inexistente ] || falha "2/$via: cópia devolveu $(resultado B)" ;;
    v1) [ "$(resultado B)" = f ] || falha "2/$via: cópia devolveu $(resultado B)" ;;
    lote) [ "$(resultado B | jq -r .registrados)" = 0 ] || falha "2/$via: lote devolveu $(resultado B)" ;;
  esac
done
fim_secao "2. exclusão trava primeiro: a cópia espera e recebe 'inexistente' (v2) / false (v1) / lote vazio; nenhuma cópia órfã"

# ---------- 3. duas exclusões simultâneas ----------
id=$(novo_codigo C3)
segura A "$(como f5_autor) select public.apagar_codigo($id)" 2
espera A "wait_event = 'PgSleep'" || falha "3: A não segurou a trava"
chama B "$(como f5_autor) select public.apagar_codigo($id);"
espera B "wait_event_type = 'Lock'" || falha "3: a segunda exclusão não esperou"
wait
[ "$(grep -v '^$' "$TMP/A.out" | head -n 1)/$(resultado B)" = "t/f" ] && [ "$(existe "$id")" = 0 ] \
  || falha "3: resultados A=$(cat "$TMP/A.out" | tr '\n' ' ') B=$(resultado B)"
fim_secao "3. duas exclusões simultâneas: a primeira apaga (true), a segunda espera e devolve false, sem erro"

# ---------- 4. quem não é o autor ----------
id=$(novo_codigo C4)
segura A "$(como f5_b) select public.copiar_codigo($id)" 3
espera A "wait_event = 'PgSleep'" || falha "4: A não segurou a trava"
t0=$(date +%s%3N)
r=$($Q -c "$(como f5_c) select public.apagar_codigo($id);" | tail -n 1)
dt=$(( $(date +%s%3N) - t0 ))
wait
[ "$r" = f ] && [ "$dt" -lt 1500 ] && [ "$(existe "$id")" = 1 ] || falha "4: não autor: retorno=$r tempo=${dt}ms código=$(existe "$id")"
r=$($Q -c "$(como f5_c) select public.apagar_codigo(-1);" | tail -n 1)
[ "$r" = f ] || falha "4: id inexistente devolveu $r"
fim_secao "4. quem não é o autor: false na hora (${dt} ms, sem esperar nem travar a linha de ninguém); id inexistente: false"

# ---------- 5. código com cópias anteriores ----------
id=$(novo_codigo C5)
$Q -c "insert into public.copias (codigo_id, usuario_id) values ($id, 'f5_b')" >/dev/null
r=$($Q -c "$(como f5_autor) select public.apagar_codigo($id);" | tail -n 1)
[ "$r" = f ] && [ "$(existe "$id")" = 1 ] && [ "$(copias_de "$id")" = 1 ] || falha "5: retorno=$r"
id=$(novo_codigo C5b)
r=$($Q -c "$(como f5_autor) select public.apagar_codigo($id);" | tail -n 1)
[ "$r" = t ] && [ "$(existe "$id")" = 0 ] || falha "5b: código sem cópias não foi apagado (retorno=$r)"
fim_secao "5. com cópia anterior: false, nada muda; sem cópias: o autor apaga (true)"

# ---------- 6. carga mista ----------
for r in $(seq 1 15); do
  $Q -c "delete from public.codigos where plataforma = 'Sorte25';
         insert into public.codigos (plataforma, codigo, autor_id) select 'Sorte25', 'M${r}_' || g, 'f5_autor' from generate_series(1, 8) g" >/dev/null
  ids=($($Q -c "select id from public.codigos where plataforma = 'Sorte25' order by id"))
  for i in 0 1 2 3 4 5 6 7; do
    chama "ap$i" "$(como f5_autor) select public.apagar_codigo(${ids[$i]});"
    if [[ $VIAS == *v2* ]]; then chama "cv$i" "$(como f5_b) select public.copiar_codigo_v2(${ids[$i]});"
    else chama "cv$i" "$(como f5_b) select json_build_object('status', case when public.copiar_codigo(${ids[$i]}) then 'registrado' else 'nao' end);"; fi
  done
  if [[ $VIAS == *lote* ]]; then
    chama "lc" "$(como f5_c) select public.pegar_lote('Sorte25', 8);"
    chama "ld" "$(como f5_d) select public.pegar_lote('Sorte25', 8);"
  else
    echo '{"registrados":0,"codigos":[]}' > "$TMP/lc.out"; echo '{"registrados":0,"codigos":[]}' > "$TMP/ld.out"
  fi
  chama "c1" "$(como f5_d) select public.copiar_codigo(${ids[3]});"
  wait
  if grep -l "ERRO" "$TMP"/ap* "$TMP"/cv* "$TMP"/l? "$TMP"/c1.out >/dev/null 2>&1; then
    falha "6/$r: $(grep -h ERRO "$TMP"/ap* "$TMP"/cv* "$TMP"/l? "$TMP"/c1.out | head -n 2)"; fi
  for i in 0 1 2 3 4 5 6 7; do
    st=$(resultado "cv$i" | jq -r .status); ap=$(resultado "ap$i"); ex=$(existe "${ids[$i]}")
    # toda cópia confirmada continua existindo; nada foi apagado depois de copiado
    if [ "$st" = registrado ]; then
      [ "$ex" = 1 ] && [ "$($Q -c "select count(*) from public.copias where codigo_id = ${ids[$i]} and usuario_id = 'f5_b'")" = 1 ] \
        || falha "6/$r: cópia confirmada de ${ids[$i]} desapareceu"
      [ "$ap" = f ] || falha "6/$r: código ${ids[$i]} copiado E apagado"
    fi
    [ "$ap" = t ] && [ "$ex" = 1 ] && falha "6/$r: exclusão disse true e o código existe"
    [ "$ap" = f ] && [ "$ex" = 0 ] && falha "6/$r: exclusão disse false e o código sumiu"
  done
  for l in lc ld; do
    for cid in $(resultado "$l" | jq -r '.codigos[].id'); do
      [ "$(existe "$cid")" = 1 ] || falha "6/$r: código $cid de um lote confirmado sumiu"
    done
  done
  # nenhum código apagado tinha cópia: não há cópia sem código (a FK garante) e
  # o total de cópias bate com o que as funções confirmaram
  conf=$(( $(for i in 0 1 2 3 4 5 6 7; do resultado "cv$i"; done | grep -c '"registrado"' || true) \
         + $(resultado lc | jq -r .registrados) + $(resultado ld | jq -r .registrados) \
         + $( [ "$(resultado c1)" = t ] && echo 1 || echo 0 ) ))
  gravadas=$($Q -c "select count(*) from public.copias p join public.codigos c on c.id = p.codigo_id where c.plataforma = 'Sorte25'")
  [ "$conf" = "$gravadas" ] || falha "6/$r: $conf cópias confirmadas, $gravadas gravadas"
done
fim_secao "6. carga mista (15 rodadas x 19 operações paralelas): nenhum impasse; toda cópia confirmada continua gravada"

$Q -c "delete from public.codigos where plataforma = 'Sorte25'" >/dev/null
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE EXCLUSÃO CONCORRENTE PASSARAM" || { echo "$falhas FALHAS"; exit 1; }
