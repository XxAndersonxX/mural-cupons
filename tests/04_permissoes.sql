-- Permissões efetivas no catálogo (o que a API do Supabase/PostgREST deixa fazer).
-- Também serve de consulta de verificação no Supabase real: as seções marcadas
-- com "MATRIZ" são só leitura e podem ser coladas no SQL Editor.
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- ---------- MATRIZ de tabelas e views ----------
select '-- tabelas/views: objeto | rls | anon(sel,ins,upd,del) | authenticated(sel,ins,upd,del) | outros(truncate,references,trigger) anon/auth';
select format('%-16s | rls=%s | anon=%s%s%s%s | auth=%s%s%s%s | outros=%s/%s', c.relname, c.relrowsecurity,
  has_table_privilege('anon', c.oid, 'select')::int, has_table_privilege('anon', c.oid, 'insert')::int,
  has_table_privilege('anon', c.oid, 'update')::int, has_table_privilege('anon', c.oid, 'delete')::int,
  has_table_privilege('authenticated', c.oid, 'select')::int, has_table_privilege('authenticated', c.oid, 'insert')::int,
  has_table_privilege('authenticated', c.oid, 'update')::int, has_table_privilege('authenticated', c.oid, 'delete')::int,
  has_table_privilege('anon', c.oid, 'truncate,references,trigger')::int,
  has_table_privilege('authenticated', c.oid, 'truncate,references,trigger')::int)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind in ('r', 'v') order by c.relname;

-- ---------- MATRIZ de funções ----------
select '-- funções: nome | security definer | search_path | anon | authenticated | PUBLIC';
select format('%-28s | definer=%s | %s | anon=%s | auth=%s | public=%s', p.proname, p.prosecdef,
  coalesce(array_to_string(p.proconfig, ','), '-'),
  has_function_privilege('anon', p.oid, 'execute')::int,
  has_function_privilege('authenticated', p.oid, 'execute')::int,
  (coalesce(p.proacl::text, '=X') ~ '(^|[{,])=X')::int)
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public' order by p.proname;

-- ---------- Asserções ----------
-- tabelas: ninguém escreve direto; anon não lê nada; migracoes fora da API
create temp table esperado_tab (obj text, auth_le boolean);
insert into esperado_tab values
  ('usuarios', true), ('codigos', true), ('copias', true), ('eventos_acesso', true), ('migracoes', false),
  ('codigos_ativos', true), ('ranking', true),
  -- migração 004: fora da API (só pelas funções)
  ('relatos_invalidos', false), ('codigos_bloqueados', false), ('eventos_invalidos', false);

select teste.ok(not exists (
  select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'v') and c.relname not in (select obj from esperado_tab)),
  'nenhuma tabela/view pública fora da lista conhecida');

select teste.ok(bool_and(not has_table_privilege('anon', c.oid, 'select') and not has_table_privilege('anon', c.oid, 'insert')
                     and not has_table_privilege('anon', c.oid, 'update') and not has_table_privilege('anon', c.oid, 'delete')),
                'anon: nenhuma permissão em nenhuma tabela/view')
from pg_class c join esperado_tab e on e.obj = c.relname join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public';

select teste.ok(bool_and(not has_table_privilege('authenticated', c.oid, 'insert') and not has_table_privilege('authenticated', c.oid, 'update')
                     and not has_table_privilege('authenticated', c.oid, 'delete')),
                'authenticated: nenhuma escrita direta em tabela/view')
from pg_class c join esperado_tab e on e.obj = c.relname join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public';

select teste.ok(bool_and(not has_table_privilege('anon', c.oid, 'truncate,references,trigger')
                     and not has_table_privilege('authenticated', c.oid, 'truncate,references,trigger')),
                'ninguém tem TRUNCATE/REFERENCES/TRIGGER')
from pg_class c join esperado_tab e on e.obj = c.relname join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public';

select teste.ok(bool_and(has_table_privilege('authenticated', c.oid, 'select') = e.auth_le),
                'authenticated: leitura só onde esperado (sempre filtrada por RLS/views)')
from pg_class c join esperado_tab e on e.obj = c.relname join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public';

select teste.ok(bool_and(c.relrowsecurity), 'RLS ligado em todas as tabelas')
from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'r';

select teste.ok(bool_and(coalesce(c.reloptions::text, '') like '%security_invoker=true%'), 'views com security_invoker (respeitam RLS)')
from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relkind = 'v';

-- funções: só as do site para authenticated; nenhuma para anon/PUBLIC
create temp table esperado_fn (nome text, auth_executa boolean);
insert into esperado_fn values
  ('eh_membro', true), ('eh_admin', true), ('entrar', true), ('entrar_v2', true),
  ('admin_alterar_acesso', true), ('postar_codigos', true), ('copiar_codigo', true), ('apagar_codigo', true),
  ('registrar_entrada', false), ('definir_primeiro_admin', false), ('recuperacao_promover_admin', false),
  -- migração 002 (só existem depois dela)
  ('copiar_codigo_v2', true), ('pegar_lote', true), ('recuperar_lote', true), ('meus_lotes', true),
  ('resumo_lote', false),
  -- migração 004
  ('relatar_invalidos', true), ('admin_codigos_invalidos', true), ('admin_confirmar_invalido', true),
  ('admin_reverter_invalido', true);

select teste.ok(not exists (
  select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname not in (select nome from esperado_fn)),
  'nenhuma função pública fora da lista conhecida');

select teste.ok(bool_and(not has_function_privilege('anon', p.oid, 'execute')), 'anon: não executa nenhuma função')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public';

select teste.ok(bool_and(coalesce(p.proacl::text, '=X') !~ '(^|[{,])=X'), 'PUBLIC: não executa nenhuma função')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public';

select teste.ok(bool_and(has_function_privilege('authenticated', p.oid, 'execute') = e.auth_executa),
                'authenticated: executa só as funções do site')
from pg_proc p join esperado_fn e on e.nome = p.proname join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public';

-- única exceção permitida: pegar_lote() da 003 também fixa lock_timeout (espera máx. 5 s)
select teste.ok(bool_and(p.prosecdef and (array_to_string(p.proconfig, ',') = 'search_path=""'
                  or (p.proname = 'pegar_lote' and array_to_string(p.proconfig, ',') = 'search_path="",lock_timeout=5s'))),
                'todas as funções: security definer com search_path vazio')
from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public';

select 'TODOS OS TESTES DE PERMISSÕES PASSARAM';
