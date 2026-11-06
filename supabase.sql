-- =====================================================================
-- Mural de Cupons — banco no Supabase (login pelo Clerk)
-- Cole tudo no SQL Editor do Supabase e clique em Run (uma vez só).
--
-- Quem é o usuário vem do token do Clerk:
--   auth.jwt()->>'sub'       = id do usuário no Clerk
--   auth.jwt()->>'username'  = nome de usuário (precisa da personalização
--                              do session token no Clerk, ver README)
-- Ninguém escreve direto nas tabelas: tudo passa pelas funções abaixo,
-- que aplicam as regras (3 cópias, 2 dias, sem repetir, etc.).
-- =====================================================================

create table if not exists public.usuarios (
  id         text primary key,
  nome       text not null unique check (nome ~ '^[A-Za-z0-9_.-]{2,40}$'),
  criado_em  timestamptz not null default now()
);

create table if not exists public.codigos (
  id          bigint generated always as identity primary key,
  plataforma  text not null check (plataforma in ('777', 'BRA365', 'Sorte25', '77')),
  codigo      text not null check (codigo ~ '^[A-Za-z0-9_-]{2,64}$'),
  autor_id    text not null references public.usuarios(id),
  criado_em   timestamptz not null default now()
);
create index if not exists codigos_busca on public.codigos (plataforma, codigo, criado_em desc);
create index if not exists codigos_data on public.codigos (criado_em desc);

create table if not exists public.copias (
  codigo_id   bigint not null references public.codigos(id) on delete cascade,
  usuario_id  text   not null references public.usuarios(id),
  criado_em   timestamptz not null default now(),
  primary key (codigo_id, usuario_id)
);

-- ---------------------------------------------------------------------
-- Segurança: só usuários logados leem; ninguém escreve direto
-- ---------------------------------------------------------------------
alter table public.usuarios enable row level security;
alter table public.codigos  enable row level security;
alter table public.copias   enable row level security;

drop policy if exists "logados leem usuarios" on public.usuarios;
drop policy if exists "logados leem codigos"  on public.codigos;
drop policy if exists "logados leem copias"   on public.copias;
create policy "logados leem usuarios" on public.usuarios for select to authenticated using (true);
create policy "logados leem codigos"  on public.codigos  for select to authenticated using (true);
create policy "logados leem copias"   on public.copias   for select to authenticated using (true);

revoke insert, update, delete on public.usuarios, public.codigos, public.copias from anon, authenticated;
revoke select on public.usuarios, public.codigos, public.copias from anon;

-- ---------------------------------------------------------------------
-- Visões usadas pelo site
-- ---------------------------------------------------------------------
create or replace view public.codigos_ativos with (security_invoker = true) as
select c.id, c.plataforma, c.codigo, c.autor_id, u.nome as autor, c.criado_em,
       count(cp.usuario_id)::int as copias,
       coalesce(array_agg(cp.usuario_id) filter (where cp.usuario_id is not null), '{}') as copiado_por
from public.codigos c
join public.usuarios u on u.id = c.autor_id
left join public.copias cp on cp.codigo_id = c.id
where c.criado_em > now() - interval '48 hours'
group by c.id, u.nome
having count(cp.usuario_id) < 3;

create or replace view public.ranking with (security_invoker = true) as
select u.id, u.nome, u.criado_em,
       (select count(*) from public.codigos c where c.autor_id = u.id)::int as postados,
       (select count(*) from public.copias  p where p.usuario_id = u.id)::int as copiados,
       (select count(*) from public.codigos_ativos a where a.autor_id = u.id)::int as ativos
from public.usuarios u;

revoke all on public.codigos_ativos, public.ranking from anon;
grant select on public.codigos_ativos, public.ranking to authenticated;

-- ---------------------------------------------------------------------
-- Funções (as únicas portas de escrita)
-- ---------------------------------------------------------------------

-- Cria/atualiza o perfil com o nome de usuário do Clerk
create or replace function public.entrar()
returns text language plpgsql security definer set search_path = public as $$
declare
  v_id   text := auth.jwt()->>'sub';
  v_nome text := auth.jwt()->>'username';
begin
  if v_id is null then raise exception 'nao_logado'; end if;
  if v_nome is null or v_nome = '' then raise exception 'sem_username_no_token'; end if;
  insert into usuarios (id, nome) values (v_id, v_nome)
  on conflict (id) do update set nome = excluded.nome;
  return v_nome;
end $$;

-- Posta vários códigos de uma vez; pula os que já estão ativos
create or replace function public.postar_codigos(p_plataforma text, p_codigos text[])
returns json language plpgsql security definer set search_path = public as $$
declare
  v_id text := auth.jwt()->>'sub';
  v_cod text;
  v_add int := 0;
  v_rep text[] := '{}';
begin
  if v_id is null or not exists (select 1 from usuarios where id = v_id) then raise exception 'nao_logado'; end if;
  if coalesce(array_length(p_codigos, 1), 0) > 200 then raise exception 'maximo_200_por_vez'; end if;
  perform pg_advisory_xact_lock(hashtext('postar:' || p_plataforma));
  foreach v_cod in array (select array(select distinct unnest(p_codigos))) loop
    if exists (select 1 from codigos c
               where c.plataforma = p_plataforma and c.codigo = v_cod
                 and c.criado_em > now() - interval '48 hours') then
      v_rep := v_rep || v_cod;
    else
      insert into codigos (plataforma, codigo, autor_id) values (p_plataforma, v_cod, v_id);
      v_add := v_add + 1;
    end if;
  end loop;
  return json_build_object('adicionados', v_add, 'repetidos', v_rep);
end $$;

-- Marca que o usuário pegou o código (1 vez por pessoa, máx. 3, não conta o próprio)
create or replace function public.copiar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_id text := auth.jwt()->>'sub';
  v_c codigos%rowtype;
begin
  if v_id is null then raise exception 'nao_logado'; end if;
  select * into v_c from codigos where id = p_id for update;
  if not found or v_c.autor_id = v_id or v_c.criado_em <= now() - interval '48 hours' then return false; end if;
  if (select count(*) from copias where codigo_id = p_id) >= 3 then return false; end if;
  insert into copias (codigo_id, usuario_id) values (p_id, v_id) on conflict do nothing;
  return found;
end $$;

-- O autor pode apagar um código seu que ninguém pegou ainda
create or replace function public.apagar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from codigos
  where id = p_id and autor_id = auth.jwt()->>'sub'
    and not exists (select 1 from copias where codigo_id = p_id);
  return found;
end $$;

revoke all on function public.entrar(), public.postar_codigos(text, text[]),
  public.copiar_codigo(bigint), public.apagar_codigo(bigint) from public, anon;
grant execute on function public.entrar(), public.postar_codigos(text, text[]),
  public.copiar_codigo(bigint), public.apagar_codigo(bigint) to authenticated;
