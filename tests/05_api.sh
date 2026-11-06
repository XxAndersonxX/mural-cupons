#!/usr/bin/env bash
# Permissões efetivas PELA API: sobe um PostgREST local (o mesmo servidor de API
# do Supabase) na frente de um banco de teste e chama cada tabela, view e função
# como cada tipo de usuário. Nunca aponta para o Supabase real.
#
# Uso: PSQL_BASE="psql -h HOST -p PORTA -U postgres" PG_HOST=HOST PG_PORT=PORTA \
#      POSTGREST=/caminho/postgrest ./tests/05_api.sh
set -euo pipefail
: "${PSQL_BASE:?}"; : "${PG_HOST:?}"; : "${PG_PORT:?}"; : "${POSTGREST:?}"
cd "$(dirname "$0")/.."

DB=mural_api_$$
PORTA_API=$((3500 + RANDOM % 400))
SEGREDO="segredo-de-teste-local-com-mais-de-32-caracteres"
TMP=$(mktemp -d)
PID=""
limpar() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null || true
  $PSQL_BASE -q -X -c "drop database if exists $DB" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap limpar EXIT

P="$PSQL_BASE -q -X -A -t -v ON_ERROR_STOP=1 -d $DB"
$PSQL_BASE -q -X -v ON_ERROR_STOP=1 -c "create database $DB" >/dev/null
$PSQL_BASE -q -X -v ON_ERROR_STOP=1 -d $DB -c "do \$\$ begin
  if not exists (select 1 from pg_roles where rolname='authenticator') then
    create role authenticator login password 'teste' noinherit; end if; end \$\$;" >/dev/null
$P -f tests/00_simular_supabase.sql >/dev/null 2>"$TMP/err" || { cat "$TMP/err"; exit 1; }
$P -c "grant anon, authenticated to authenticator" >/dev/null
$P -f supabase.sql >/dev/null 2>"$TMP/err" || { cat "$TMP/err"; exit 1; }
$P -f migrations/001_membros.sql >/dev/null 2>"$TMP/err" || { cat "$TMP/err"; exit 1; }

# um usuário de cada tipo + um código
$P >/dev/null <<'SQL'
insert into public.usuarios (id, nome, papel, situacao) values
  ('u_admin', 'admin1', 'admin', 'ativo'), ('u_membro', 'membro1', 'membro', 'ativo'),
  ('u_pend', 'pend1', 'pendente', 'ativo'), ('u_rej', 'rej1', 'pendente', 'rejeitado'),
  ('u_susp', 'susp1', 'membro', 'suspenso');
insert into public.codigos (plataforma, codigo, autor_id) values ('777', 'APICOD1', 'u_admin');
insert into public.eventos_acesso (alvo_id, acao) values ('u_pend', 'solicitou');
SQL
ID=$($P -c "select id from public.codigos where codigo='APICOD1'")

cat > "$TMP/pgrst.conf" <<EOF
db-uri = "postgres://authenticator:teste@$PG_HOST:$PG_PORT/$DB"
db-schemas = "public"
db-anon-role = "anon"
jwt-secret = "$SEGREDO"
server-port = $PORTA_API
server-host = "127.0.0.1"
log-level = "crit"
EOF
"$POSTGREST" "$TMP/pgrst.conf" >"$TMP/pgrst.log" 2>&1 &
PID=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORTA_API/" && break; sleep 0.2; done
curl -s -o /dev/null "http://127.0.0.1:$PORTA_API/" || { echo "PostgREST não subiu"; cat "$TMP/pgrst.log"; exit 1; }

token() {  # token igual ao do Clerk para o Supabase: sub, username, role=authenticated
  python3 -I -c '
import base64, hashlib, hmac, json, sys, time
b = lambda d: base64.urlsafe_b64encode(json.dumps(d, separators=(",", ":")).encode()).rstrip(b"=")
h, p = b({"alg": "HS256", "typ": "JWT"}), b({"sub": sys.argv[1], "username": sys.argv[2], "role": "authenticated", "exp": int(time.time()) + 600})
s = base64.urlsafe_b64encode(hmac.new(sys.argv[3].encode(), h + b"." + p, hashlib.sha256).digest()).rstrip(b"=")
print((h + b"." + p + b"." + s).decode())' "$1" "$2" "$SEGREDO"
}
declare -A TK
TK[anon]=""
TK[estranho]=$(token u_estranho estranho1)
TK[pendente]=$(token u_pend pend1)
TK[rejeitado]=$(token u_rej rej1)
TK[suspenso]=$(token u_susp susp1)
TK[membro]=$(token u_membro membro1)
TK[admin]=$(token u_admin admin1)

falhas=0; total=0
# chama: perfil método caminho corpo  -> imprime "STATUS CORPO"
chama() {
  local auth=()
  [ -n "${TK[$1]}" ] && auth=(-H "Authorization: Bearer ${TK[$1]}")
  curl -s -X "$2" "http://127.0.0.1:$PORTA_API$3" "${auth[@]}" -H "Content-Type: application/json" \
       -H "Prefer: return=representation" ${4:+-d "$4"} -w ' %{http_code}' \
    | tr -d '\n' | sed -E 's/^(.*) ([0-9]{3})$/\2 \1/'   # "STATUS CORPO" numa linha só
}
# confere: perfil método caminho corpo regex-esperada descrição
confere() {
  total=$((total + 1))
  local r; r=$(chama "$1" "$2" "$3" "$4")
  if [[ "$r" =~ $5 ]]; then printf 'ok  %-10s %-6s %-38s -> %s\n' "$1" "$2" "$3" "${r:0:60}"
  else printf 'FALHOU %-10s %-6s %-38s esperado /%s/ veio: %s\n' "$1" "$2" "$3" "$5" "${r:0:160}"; falhas=$((falhas + 1)); fi
}

NEGADO='^(401|403) .*42501'          # permission denied
VAZIO='^200 \[\] ?$'
UM='^200 \[\{'
for perfil in anon estranho pendente rejeitado suspenso membro admin; do
  case $perfil in
    anon) for t in usuarios codigos copias eventos_acesso migracoes codigos_ativos ranking; do confere $perfil GET "/$t" "" "$NEGADO"; done ;;
    estranho|rejeitado|suspenso|pendente)
      for t in codigos copias codigos_ativos ranking eventos_acesso; do confere $perfil GET "/$t" "" "$VAZIO"; done
      if [ $perfil = estranho ]; then confere $perfil GET "/usuarios" "" "$VAZIO"
      else confere $perfil GET "/usuarios?select=nome" "" '^200 \[\{"nome":"[a-z0-9]+"\}\] ?$'; fi ;;
    membro)
      confere $perfil GET "/codigos?select=codigo&codigo=eq.APICOD1" "" '^200 \[\{"codigo":"APICOD1"\}\]'
      confere $perfil GET "/codigos_ativos?select=codigo&codigo=eq.APICOD1" "" '^200 \[\{"codigo":"APICOD1"\}\]'
      confere $perfil GET "/ranking?select=nome&order=nome" "" '^200 \[\{"nome":"admin1"\}, *\{"nome":"membro1"\}\]'
      confere $perfil GET "/usuarios?select=nome&order=nome" "" '^200 \[\{"nome":"admin1"\}, *\{"nome":"membro1"\}\]'
      confere $perfil GET "/eventos_acesso" "" "$VAZIO" ;;
    admin)
      confere $perfil GET "/usuarios?select=id" "" '^200 (\[.*){1}"u_susp"'
      confere $perfil GET "/eventos_acesso?select=acao" "" '^200 \[\{"acao":"solicitou"\}\]'
      confere $perfil GET "/codigos_ativos?select=codigo&codigo=eq.APICOD1" "" '^200 \[\{"codigo":"APICOD1"\}\]' ;;
  esac
  [ $perfil != anon ] && confere $perfil GET "/migracoes" "" "$NEGADO"

  # escrita direta: sempre negada
  confere $perfil PATCH "/usuarios?id=eq.u_pend" '{"papel":"admin"}' '^(401|403) .*42501'
  confere $perfil POST  "/eventos_acesso" '{"alvo_id":"u_pend","acao":"aprovou"}' '^(401|403) .*42501'
  confere $perfil POST  "/codigos" '{"plataforma":"777","codigo":"HACK1","autor_id":"u_admin"}' '^(401|403) .*42501'
  confere $perfil DELETE "/codigos?id=eq.$ID" "" '^(401|403) .*42501'

  # funções só do SQL Editor / internas: sempre negadas
  confere $perfil POST "/rpc/definir_primeiro_admin" '{"p_nome":"pend1"}' '^(401|403) .*42501'
  confere $perfil POST "/rpc/recuperacao_promover_admin" '{"p_nome":"pend1","p_motivo":"tentativa"}' '^(401|403) .*42501'
  confere $perfil POST "/rpc/registrar_entrada" '{}' '^(401|403) .*42501'

  # operações de membro e de admin
  case $perfil in
    anon)
      for f in entrar entrar_v2 eh_membro; do confere $perfil POST "/rpc/$f" '{}' '^401 .*42501'; done
      confere $perfil POST "/rpc/postar_codigos" '{"p_plataforma":"777","p_codigos":["X1"]}' '^401 .*42501'
      confere $perfil POST "/rpc/admin_alterar_acesso" '{"p_alvo":"u_pend","p_acao":"aprovar"}' '^401 .*42501' ;;
    membro|admin)
      confere $perfil POST "/rpc/eh_membro" '{}' '^200 true'
      confere $perfil POST "/rpc/postar_codigos" "{\"p_plataforma\":\"BRA365\",\"p_codigos\":[\"OK_$perfil\"]}" '^200 \{"adicionados" ?: ?1' ;;
    *)
      confere $perfil POST "/rpc/eh_membro" '{}' '^200 false'
      confere $perfil POST "/rpc/postar_codigos" '{"p_plataforma":"777","p_codigos":["X1"]}' '^400 .*acesso_negado'
      confere $perfil POST "/rpc/copiar_codigo" "{\"p_id\":$ID}" '^400 .*acesso_negado'
      confere $perfil POST "/rpc/apagar_codigo" "{\"p_id\":$ID}" '^400 .*acesso_negado' ;;
  esac
  [ $perfil != admin ] && [ $perfil != anon ] && \
    confere $perfil POST "/rpc/admin_alterar_acesso" '{"p_alvo":"u_pend","p_acao":"aprovar"}' '^400 .*nao_admin'
done

# login pela API: estranho vira pendente (e continua sem acesso); entrar() antigo devolve texto
confere estranho POST "/rpc/entrar_v2" '{}' '^200 \{"id" ?: ?"u_estranho".*"papel" ?: ?"pendente".*"acesso" ?: ?false'
confere estranho POST "/rpc/entrar" '{}' '^200 "estranho1"'
confere estranho GET  "/codigos" "" "$VAZIO"
# admin aprova pelo site -> acesso liberado na hora
confere admin    POST "/rpc/admin_alterar_acesso" '{"p_alvo":"u_estranho","p_acao":"aprovar"}' '^200 \{"id" ?: ?"u_estranho".*"membro"'
confere estranho GET  "/codigos?select=codigo&codigo=eq.APICOD1" "" '^200 \[\{"codigo":"APICOD1"\}\]'
# admin suspende -> corta na hora
confere admin    POST "/rpc/admin_alterar_acesso" '{"p_alvo":"u_estranho","p_acao":"suspender"}' '^200 .*"suspenso"'
confere estranho GET  "/codigos" "" "$VAZIO"

echo "$((total - falhas))/$total verificações pela API"
[ "$falhas" = 0 ] && echo "TODOS OS TESTES DE API PASSARAM" || { echo "$falhas FALHAS NA API"; exit 1; }
