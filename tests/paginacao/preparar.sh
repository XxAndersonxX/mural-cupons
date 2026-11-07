#!/usr/bin/env bash
# Prepara o teste de paginação (tests/paginacao/teste_paginacao.js). Só LOCAL.
# Uso: POSTGREST=/caminho/postgrest [PSQL_BASE="psql -h ... -U postgres"] tests/paginacao/preparar.sh
# Postgres local na porta 5499 (a mesma do PSQL_BASE); sobe PostgREST em 3999 e 3998.
# banco local + 2 PostgREST (max-rows 1000 como o Supabase; e 200 para testar servidor com limite < página)
set -euo pipefail
S=$(cd "$(dirname "$0")" && pwd); R=$(cd "$S/../.." && pwd)
: "${POSTGREST:?defina POSTGREST=/caminho/postgrest}"
: "${PSQL_BASE:=psql -h 127.0.0.1 -p 5499 -U postgres}"
W=${TMPDIR:-/tmp}/mural_paginacao; mkdir -p "$W"
PB="$PSQL_BASE -q -X -v ON_ERROR_STOP=1"
pkill -f "pgrst_pag" 2>/dev/null || true
$PB -c "drop database if exists mural_pag" -c "create database mural_pag" >/dev/null
$PB -c "do \$\$ begin if not exists (select 1 from pg_roles where rolname='authenticator') then
  create role authenticator login password 'teste' noinherit; end if; end \$\$;" >/dev/null
P="$PB -d mural_pag"
$P -f $R/tests/00_simular_supabase.sql >/dev/null
$P -c "grant anon, authenticated to authenticator" >/dev/null
for f in supabase.sql migrations/001_membros.sql migrations/002_copias_ranking.sql migrations/003_distribuicao_hibrida.sql; do $P -f $R/$f >/dev/null 2>&1; done
$P >/dev/null <<'SQL'
insert into public.usuarios (id, nome, papel, situacao) values
 ('user_anderson', 'anderson', 'admin', 'ativo'), ('user_cafe', 'cafe', 'membro', 'ativo'),
 ('user_pedro', 'pedro', 'membro', 'ativo'), ('user_joao', 'joao', 'membro', 'ativo'),
 ('user_pend', 'pend', 'pendente', 'ativo'), ('user_susp', 'susp', 'membro', 'suspenso');
-- gera n códigos ativos (+ alguns inativos que não podem aparecer) em 4 plataformas e 4 autores
create or replace function teste.gera(n int) returns void language plpgsql as $$
begin
  delete from public.codigos;
  insert into public.codigos (plataforma, codigo, autor_id, criado_em)
  select (array['777','BRA365','Sorte25','77'])[1 + g % 4], 'C' || g,
         (array['user_anderson','user_cafe','user_pedro','user_joao'])[1 + (g / 4) % 4],
         now() - ((g * 7919) % 2800) * interval '1 minute'
    from generate_series(1, n) g;
  -- inativos: vencido e esgotado (nunca entram)
  insert into public.codigos (plataforma, codigo, autor_id, criado_em) values
    ('777', 'VENCIDO', 'user_cafe', now() - interval '49 hours'), ('777', 'ESGOTADO', 'user_cafe', now() - interval '1 hour');
  insert into public.copias (codigo_id, usuario_id)
  select id, u from public.codigos, unnest(array['user_anderson','user_joao','user_pend']) u where codigo = 'ESGOTADO';
end $$;
-- o que a view mostra para um membro (mesmo filtro da codigos_ativos)
create or replace function teste.ativos() returns setof bigint language sql as $$
  select c.id from public.codigos c where c.criado_em > now() - interval '48 hours'
     and (select count(*) from public.copias p where p.codigo_id = c.id) < 3 order by c.id;
$$;
SQL
for par in "3999 1000" "3998 200"; do
  set -- $par
  cat > $W/pgrst_$1.conf <<CONF
db-uri = "postgres://authenticator:teste@127.0.0.1:5499/mural_pag"
db-schemas = "public"
db-anon-role = "anon"
db-max-rows = $2
jwt-secret = "segredo-de-teste-local-com-mais-de-32-caracteres"
server-port = $1
server-host = "127.0.0.1"
log-level = "crit"
CONF
  (exec -a pgrst_pag_$1 "$POSTGREST" $W/pgrst_$1.conf >$W/pgrst_$1.log 2>&1 &)
done
for p in 3999 3998; do for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:$p/ && break; sleep 0.2; done; done
# páginas de teste: index.html apontando para o PostgREST LOCAL (nunca o Supabase real)
mkdir -p $W/web
mk() { sed -e "s#^const SUPABASE_URL          = \".*\";#const SUPABASE_URL          = \"http://127.0.0.1:$2\";#" \
           -e 's#^const SUPABASE_KEY          = ".*";#const SUPABASE_KEY          = "chave-local-de-teste";#' > $W/web/$1; grep -q "127.0.0.1:$2" $W/web/$1; }
mk novo.html 3999 < $R/index.html
mk novo200.html 3998 < $R/index.html
git -C $R show origin/main:index.html | mk main.html 3999
(cd $W/web && exec -a pgrst_pag_site python3 -m http.server 8771 >/dev/null 2>&1 &)
sleep 1
echo "ambiente pronto em $W (site em http://localhost:8771)"
