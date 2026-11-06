-- Só para testes locais: imita o que o Supabase já tem (papéis e auth.jwt()).
-- NÃO rodar no Supabase.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create schema if not exists auth;
create or replace function auth.jwt() returns jsonb language sql stable as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), ''), '{}')::jsonb
$$;
grant usage on schema auth to anon, authenticated;
grant execute on function auth.jwt() to anon, authenticated;
grant usage on schema public to anon, authenticated;
-- o Supabase concede privilégios padrão nas tabelas novas; imitamos isso
alter default privileges in schema public grant all on tables to anon, authenticated;
alter default privileges in schema public grant execute on functions to anon, authenticated;

-- utilitários de teste
create schema if not exists teste;
grant usage on schema teste to anon, authenticated;

create or replace function teste.como(p_sub text, p_username text default null) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_strip_nulls(json_build_object('sub', p_sub, 'username', p_username, 'role', 'authenticated'))::text, false);
end $$;

create or replace function teste.ok(p_cond boolean, p_nome text) returns text language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'FALHOU: %', p_nome; end if;
  return 'ok  ' || p_nome;
end $$;

-- executa SQL e exige que dê erro contendo p_trecho
create or replace function teste.erro(p_sql text, p_trecho text, p_nome text) returns text language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_trecho in sqlerrm) > 0 then return 'ok  ' || p_nome; end if;
    raise exception 'FALHOU: % (erro diferente: %)', p_nome, sqlerrm;
  end;
  raise exception 'FALHOU: % (não deu erro)', p_nome;
end $$;

-- conta linhas visíveis para o papel atual (respeita RLS)
create or replace function teste.contar(p_sql text) returns bigint language plpgsql as $$
declare n bigint;
begin
  execute 'select count(*) from (' || p_sql || ') x' into n;
  return n;
end $$;

grant execute on all functions in schema teste to anon, authenticated;
