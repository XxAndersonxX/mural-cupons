#!/usr/bin/env bash
# Verificação no Supabase real, como VISITANTE ANÔNIMO (sem login): nenhuma
# tabela, view ou função do mural pode responder. Só aceita recusa por permissão
# (401/403); 404 conta como FALHA (URL errada ou função com outro nome).
#
# Não grava nada: cada função é chamada com os parâmetros certos e valores
# inofensivos (usuário/código inexistentes). Mesmo que a permissão estivesse
# errada, as próprias funções recusariam sem gravar.
#
# Uso: SUPABASE_URL=https://xxxx.supabase.co SUPABASE_KEY=sb_publishable_... ./tests/verificar_supabase_anon.sh
set -uo pipefail
: "${SUPABASE_URL:?}"; : "${SUPABASE_KEY:?}"
PREFIXO="${API_PREFIXO-/rest/v1}"   # testes locais com PostgREST puro usam API_PREFIXO=""
falhas=0
pede() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "$SUPABASE_URL$PREFIXO$2" -H "apikey: $SUPABASE_KEY" \
           -H "Content-Type: application/json" ${3:+-d "$3"}; }
confere() {  # rótulo código
  if [[ $2 == 401 || $2 == 403 ]]; then echo "ok  $1 -> $2 (bloqueado)"; else echo "FALHOU $1 -> $2"; falhas=$((falhas + 1)); fi
}
for t in usuarios codigos copias eventos_acesso migracoes codigos_ativos ranking; do
  confere "GET /$t" "$(pede GET "/$t?select=*&limit=1")"
done
X='"u_inexistente_verificacao"'
confere "RPC entrar"                     "$(pede POST /rpc/entrar '{}')"
confere "RPC entrar_v2"                  "$(pede POST /rpc/entrar_v2 '{}')"
confere "RPC eh_membro"                  "$(pede POST /rpc/eh_membro '{}')"
confere "RPC eh_admin"                   "$(pede POST /rpc/eh_admin '{}')"
confere "RPC registrar_entrada"          "$(pede POST /rpc/registrar_entrada '{}')"
confere "RPC definir_primeiro_admin"     "$(pede POST /rpc/definir_primeiro_admin "{\"p_nome\":$X}")"
confere "RPC recuperacao_promover_admin" "$(pede POST /rpc/recuperacao_promover_admin "{\"p_nome\":$X,\"p_motivo\":\"verificacao\"}")"
confere "RPC admin_alterar_acesso"       "$(pede POST /rpc/admin_alterar_acesso "{\"p_alvo\":$X,\"p_acao\":\"aprovar\"}")"
confere "RPC postar_codigos"             "$(pede POST /rpc/postar_codigos '{"p_plataforma":"777","p_codigos":[]}')"
confere "RPC copiar_codigo"              "$(pede POST /rpc/copiar_codigo '{"p_id":-1}')"
confere "RPC apagar_codigo"              "$(pede POST /rpc/apagar_codigo '{"p_id":-1}')"
[ $falhas = 0 ] && echo "VISITANTE ANÔNIMO NÃO ACESSA NADA" || { echo "$falhas FALHAS"; exit 1; }
