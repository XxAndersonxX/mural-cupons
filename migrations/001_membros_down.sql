-- =====================================================================
-- Reversão da migração 001 — volta o comportamento ao supabase.sql original
--
-- Não apaga dados: as colunas papel/situacao/atualizado_em e a tabela
-- eventos_acesso ficam no banco (sem uso). Se quiser removê-las de vez,
-- rode a seção "LIMPEZA OPCIONAL" no final, que é destrutiva para esses
-- dados novos (papéis e histórico de aprovações). Códigos e cópias não
-- são tocados em nenhum caso.
-- =====================================================================
begin;

-- políticas originais
drop policy if exists "usuarios: admin, membros ativos ou o proprio" on public.usuarios;
drop policy if exists "codigos: membros ativos" on public.codigos;
drop policy if exists "copias: membros ativos"  on public.copias;
drop policy if exists "eventos: admins"         on public.eventos_acesso;
drop policy if exists "logados leem usuarios" on public.usuarios;
drop policy if exists "logados leem codigos"  on public.codigos;
drop policy if exists "logados leem copias"   on public.copias;
create policy "logados leem usuarios" on public.usuarios for select to authenticated using (true);
create policy "logados leem codigos"  on public.codigos  for select to authenticated using (true);
create policy "logados leem copias"   on public.copias   for select to authenticated using (true);
revoke all on public.eventos_acesso from authenticated;

-- views originais
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

-- funções originais
drop function if exists public.admin_alterar_acesso(text, text, text, timestamptz);
drop function if exists public.definir_primeiro_admin(text);
drop function if exists public.recuperacao_promover_admin(text, text);
drop function if exists public.entrar_v2();
drop function if exists public.entrar();
drop function if exists public.registrar_entrada();
create function public.entrar()
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

create or replace function public.apagar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from codigos
  where id = p_id and autor_id = auth.jwt()->>'sub'
    and not exists (select 1 from copias where codigo_id = p_id);
  return found;
end $$;

drop function if exists public.eh_admin();
drop function if exists public.eh_membro();

revoke all on function public.entrar(), public.postar_codigos(text, text[]),
  public.copiar_codigo(bigint), public.apagar_codigo(bigint) from public, anon;
grant execute on function public.entrar(), public.postar_codigos(text, text[]),
  public.copiar_codigo(bigint), public.apagar_codigo(bigint) to authenticated;

update public.migracoes set revertida_em = now() where versao = '001_membros';

commit;

-- ---------------------------------------------------------------------
-- LIMPEZA OPCIONAL (destrutiva para papéis e auditoria). Só se tiver certeza.
-- ---------------------------------------------------------------------
-- begin;
-- drop table if exists public.eventos_acesso;
-- (depois disso, reaplicar a 001 conta como PRIMEIRA APLICAÇÃO: todos voltam a pendente)
-- alter table public.usuarios drop constraint if exists usuarios_papel_situacao_check;
-- alter table public.usuarios drop constraint if exists usuarios_situacao_check;
-- alter table public.usuarios drop constraint if exists usuarios_papel_check;
-- drop index if exists public.usuarios_papel_situacao;
-- alter table public.usuarios drop column if exists papel,
--                             drop column if exists situacao,
--                             drop column if exists atualizado_em;
-- commit;
