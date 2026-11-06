-- =====================================================================
-- Migração 001 — Sistema de membros (pendente / membro / admin)
--
-- O que faz (NÃO apaga nem altera dados existentes de códigos e cópias):
--   * usuarios ganha: papel, situacao, atualizado_em
--     - todos os usuários já existentes ficam como PENDENTES
--   * nova tabela eventos_acesso (auditoria de aprovações etc.)
--   * eh_membro() / eh_admin(): quem pode ver e fazer o quê
--   * políticas de leitura passam a exigir membro ativo
--   * views só devolvem dados para membros ativos
--   * entrar() passa a devolver {nome, papel, situacao, acesso}
--   * admin_alterar_acesso(): aprovar, rejeitar, suspender, reativar,
--     promover_admin, remover_admin — só administradores, com auditoria
--   * definir_primeiro_admin(): uso ÚNICO no SQL Editor, só funciona
--     enquanto não existir nenhum administrador
--   * postar/copiar/apagar exigem membro ativo
--   * funções security definer com search_path vazio (endurecimento)
--
-- Como aplicar: Supabase → SQL Editor → colar este arquivo → Run.
-- Depois, UMA vez:  select public.definir_primeiro_admin('SEU_USERNAME');
-- Reverter: migrations/001_membros_down.sql
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 1. Colunas novas em usuarios (aditivo)
-- ---------------------------------------------------------------------
alter table public.usuarios
  add column if not exists papel         text        not null default 'pendente',
  add column if not exists situacao      text        not null default 'ativo',
  add column if not exists atualizado_em timestamptz not null default now();

alter table public.usuarios drop constraint if exists usuarios_papel_check;
alter table public.usuarios add  constraint usuarios_papel_check
  check (papel in ('pendente', 'membro', 'admin'));

alter table public.usuarios drop constraint if exists usuarios_situacao_check;
alter table public.usuarios add  constraint usuarios_situacao_check
  check (situacao in ('ativo', 'rejeitado', 'suspenso'));

-- rejeitado só faz sentido para pendente; suspenso só para membro/admin
alter table public.usuarios drop constraint if exists usuarios_papel_situacao_check;
alter table public.usuarios add  constraint usuarios_papel_situacao_check
  check ((papel = 'pendente' and situacao in ('ativo', 'rejeitado'))
      or (papel in ('membro', 'admin') and situacao in ('ativo', 'suspenso')));

create index if not exists usuarios_papel_situacao on public.usuarios (papel, situacao);

-- ---------------------------------------------------------------------
-- 2. Auditoria
-- ---------------------------------------------------------------------
create table if not exists public.eventos_acesso (
  id              bigint generated always as identity primary key,
  alvo_id         text not null references public.usuarios(id),
  acao            text not null check (acao in ('solicitou', 'aprovou', 'rejeitou', 'suspendeu', 'reativou',
                                                'promoveu_admin', 'removeu_admin', 'primeiro_admin')),
  por_id          text references public.usuarios(id),          -- null = sistema / SQL Editor
  motivo          text check (motivo is null or char_length(motivo) <= 300),
  papel_antes     text,
  situacao_antes  text,
  papel_depois    text,
  situacao_depois text,
  criado_em       timestamptz not null default now()
);
create index if not exists eventos_acesso_data on public.eventos_acesso (criado_em desc);
alter table public.eventos_acesso enable row level security;
revoke all on public.eventos_acesso from anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. Quem é membro / admin (usadas nas políticas e nas funções)
-- ---------------------------------------------------------------------
create or replace function public.eh_membro()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.usuarios u
    where u.id = (auth.jwt() ->> 'sub')
      and u.papel in ('membro', 'admin')
      and u.situacao = 'ativo');
$$;

create or replace function public.eh_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.usuarios u
    where u.id = (auth.jwt() ->> 'sub')
      and u.papel = 'admin'
      and u.situacao = 'ativo');
$$;

-- ---------------------------------------------------------------------
-- 4. Políticas de leitura (substituem as "logados leem ...")
-- ---------------------------------------------------------------------
drop policy if exists "logados leem usuarios" on public.usuarios;
drop policy if exists "logados leem codigos"  on public.codigos;
drop policy if exists "logados leem copias"   on public.copias;
drop policy if exists "usuarios: admin, membros ativos ou o proprio" on public.usuarios;
drop policy if exists "codigos: membros ativos" on public.codigos;
drop policy if exists "copias: membros ativos"  on public.copias;
drop policy if exists "eventos: admins"         on public.eventos_acesso;

-- admin vê todos; membro ativo vê só membros ativos; qualquer um vê a própria linha
create policy "usuarios: admin, membros ativos ou o proprio" on public.usuarios
  for select to authenticated using (
    (select public.eh_admin())
    or ((select public.eh_membro()) and papel in ('membro', 'admin') and situacao = 'ativo')
    or id = (select auth.jwt() ->> 'sub'));

create policy "codigos: membros ativos" on public.codigos
  for select to authenticated using ((select public.eh_membro()));

create policy "copias: membros ativos" on public.copias
  for select to authenticated using ((select public.eh_membro()));

create policy "eventos: admins" on public.eventos_acesso
  for select to authenticated using ((select public.eh_admin()));

grant select on public.eventos_acesso to authenticated;

-- ---------------------------------------------------------------------
-- 5. Views: só devolvem algo para membros ativos (reforço além do RLS)
-- ---------------------------------------------------------------------
create or replace view public.codigos_ativos with (security_invoker = true) as
select c.id, c.plataforma, c.codigo, c.autor_id, u.nome as autor, c.criado_em,
       count(cp.usuario_id)::int as copias,
       coalesce(array_agg(cp.usuario_id) filter (where cp.usuario_id is not null), '{}') as copiado_por
from public.codigos c
join public.usuarios u on u.id = c.autor_id
left join public.copias cp on cp.codigo_id = c.id
where c.criado_em > now() - interval '48 hours'
  and (select public.eh_membro())
group by c.id, u.nome
having count(cp.usuario_id) < 3;

create or replace view public.ranking with (security_invoker = true) as
select u.id, u.nome, u.criado_em,
       (select count(*) from public.codigos c where c.autor_id = u.id)::int as postados,
       (select count(*) from public.copias  p where p.usuario_id = u.id)::int as copiados,
       (select count(*) from public.codigos_ativos a where a.autor_id = u.id)::int as ativos
from public.usuarios u
where (select public.eh_membro())
  and u.papel in ('membro', 'admin') and u.situacao = 'ativo';

-- ---------------------------------------------------------------------
-- 6. entrar(): cria a solicitação e devolve o estado do acesso
--    (o tipo de retorno muda de text para json, por isso o drop)
-- ---------------------------------------------------------------------
drop function if exists public.entrar();
create function public.entrar()
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id   text := auth.jwt() ->> 'sub';
  v_nome text := auth.jwt() ->> 'username';
  v_novo boolean;
  v_u    public.usuarios%rowtype;
begin
  if v_id is null or v_id = '' then raise exception 'nao_logado'; end if;
  if v_nome is null or v_nome = '' then raise exception 'sem_username_no_token'; end if;
  if v_nome !~ '^[A-Za-z0-9_.-]{2,40}$' then raise exception 'username_invalido'; end if;

  begin
    insert into public.usuarios (id, nome) values (v_id, v_nome)
    on conflict (id) do update
      set nome = excluded.nome,
          atualizado_em = case when public.usuarios.nome is distinct from excluded.nome
                               then now() else public.usuarios.atualizado_em end
    returning (xmax = 0) into v_novo;   -- true = linha nova (primeiro acesso)
  exception when unique_violation then
    raise exception 'nome_em_uso';      -- outra conta já usa esse nome no mural
  end;

  select * into v_u from public.usuarios where id = v_id;
  if v_novo then
    insert into public.eventos_acesso (alvo_id, acao, papel_depois, situacao_depois)
    values (v_id, 'solicitou', v_u.papel, v_u.situacao);
  end if;

  return json_build_object(
    'id', v_u.id, 'nome', v_u.nome, 'papel', v_u.papel, 'situacao', v_u.situacao,
    'acesso', v_u.papel in ('membro', 'admin') and v_u.situacao = 'ativo');
end $$;

-- ---------------------------------------------------------------------
-- 7. Administração de acesso
-- ---------------------------------------------------------------------
-- p_versao: o atualizado_em que o admin estava vendo. Se outro admin mudou o
-- usuário nesse meio-tempo, a ação é recusada (estado_mudou) em vez de
-- sobrescrever a decisão dele.
create or replace function public.admin_alterar_acesso(p_alvo text, p_acao text, p_motivo text default null,
                                                       p_versao timestamptz default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_admin  text := auth.jwt() ->> 'sub';
  v_u      public.usuarios%rowtype;
  v_papel  text;
  v_sit    text;
  v_evento text;
begin
  -- todas as ações de acesso passam por uma fila única: evita, por exemplo,
  -- dois admins removendo um ao outro ao mesmo tempo
  perform pg_advisory_xact_lock(hashtext('mural:admin_alterar_acesso'));

  if not public.eh_admin() then raise exception 'nao_admin'; end if;
  if p_alvo is null or p_alvo = v_admin then raise exception 'nao_pode_alterar_a_si_mesmo'; end if;
  if p_motivo is not null and char_length(p_motivo) > 300 then raise exception 'motivo_longo'; end if;

  select * into v_u from public.usuarios where id = p_alvo for update;
  if not found then raise exception 'usuario_inexistente'; end if;
  if p_versao is not null and v_u.atualizado_em is distinct from p_versao then
    raise exception 'estado_mudou';
  end if;

  case p_acao
    when 'aprovar' then
      if v_u.papel <> 'pendente' then raise exception 'acao_invalida'; end if;
      v_papel := 'membro'; v_sit := 'ativo'; v_evento := 'aprovou';
    when 'rejeitar' then
      if not (v_u.papel = 'pendente' and v_u.situacao = 'ativo') then raise exception 'acao_invalida'; end if;
      v_papel := 'pendente'; v_sit := 'rejeitado'; v_evento := 'rejeitou';
    when 'suspender' then
      if not (v_u.papel in ('membro', 'admin') and v_u.situacao = 'ativo') then raise exception 'acao_invalida'; end if;
      v_papel := v_u.papel; v_sit := 'suspenso'; v_evento := 'suspendeu';
    when 'reativar' then
      if not (v_u.papel in ('membro', 'admin') and v_u.situacao = 'suspenso') then raise exception 'acao_invalida'; end if;
      v_papel := v_u.papel; v_sit := 'ativo'; v_evento := 'reativou';
    when 'promover_admin' then
      if not (v_u.papel = 'membro' and v_u.situacao = 'ativo') then raise exception 'acao_invalida'; end if;
      v_papel := 'admin'; v_sit := 'ativo'; v_evento := 'promoveu_admin';
    when 'remover_admin' then
      if v_u.papel <> 'admin' then raise exception 'acao_invalida'; end if;
      v_papel := 'membro'; v_sit := v_u.situacao; v_evento := 'removeu_admin';
    else
      raise exception 'acao_invalida';
  end case;

  update public.usuarios
     set papel = v_papel, situacao = v_sit, atualizado_em = now()
   where id = p_alvo;

  -- nunca deixar o mural sem administrador ativo
  if not exists (select 1 from public.usuarios where papel = 'admin' and situacao = 'ativo') then
    raise exception 'ultimo_admin';
  end if;

  insert into public.eventos_acesso (alvo_id, acao, por_id, motivo, papel_antes, situacao_antes, papel_depois, situacao_depois)
  values (p_alvo, v_evento, v_admin, nullif(trim(p_motivo), ''), v_u.papel, v_u.situacao, v_papel, v_sit);

  return json_build_object('id', p_alvo, 'nome', v_u.nome, 'papel', v_papel, 'situacao', v_sit);
end $$;

-- Uso único, só no SQL Editor (não é liberada para o site)
create or replace function public.definir_primeiro_admin(p_nome text)
returns text language plpgsql security definer set search_path = '' as $$
declare v_u public.usuarios%rowtype;
begin
  perform pg_advisory_xact_lock(hashtext('mural:admin_alterar_acesso'));
  if exists (select 1 from public.usuarios where papel = 'admin') then
    raise exception 'ja_existe_admin';
  end if;
  select * into v_u from public.usuarios where nome = p_nome for update;
  if not found then raise exception 'usuario_inexistente: entre no site uma vez com esse usuário antes'; end if;
  update public.usuarios set papel = 'admin', situacao = 'ativo', atualizado_em = now() where id = v_u.id;
  insert into public.eventos_acesso (alvo_id, acao, papel_antes, situacao_antes, papel_depois, situacao_depois)
  values (v_u.id, 'primeiro_admin', v_u.papel, v_u.situacao, 'admin', 'ativo');
  return v_u.nome || ' agora é administrador';
end $$;

-- ---------------------------------------------------------------------
-- 8. Operações de membro: mesmas regras de antes + exigência de membro ativo
--    (mesmos parâmetros e retornos; só endurecidas)
-- ---------------------------------------------------------------------
create or replace function public.postar_codigos(p_plataforma text, p_codigos text[])
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id  text := auth.jwt() ->> 'sub';
  v_cod text;
  v_add int := 0;
  v_rep text[] := '{}';
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  if coalesce(array_length(p_codigos, 1), 0) > 200 then raise exception 'maximo_200_por_vez'; end if;
  perform pg_advisory_xact_lock(hashtext('postar:' || p_plataforma));
  foreach v_cod in array (select array(select distinct unnest(p_codigos))) loop
    if exists (select 1 from public.codigos c
               where c.plataforma = p_plataforma and c.codigo = v_cod
                 and c.criado_em > now() - interval '48 hours') then
      v_rep := v_rep || v_cod;
    else
      insert into public.codigos (plataforma, codigo, autor_id) values (p_plataforma, v_cod, v_id);
      v_add := v_add + 1;
    end if;
  end loop;
  return json_build_object('adicionados', v_add, 'repetidos', v_rep);
end $$;

create or replace function public.copiar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_id text := auth.jwt() ->> 'sub';
  v_c  public.codigos%rowtype;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  select * into v_c from public.codigos where id = p_id for update;
  if not found or v_c.autor_id = v_id or v_c.criado_em <= now() - interval '48 hours' then return false; end if;
  if (select count(*) from public.copias where codigo_id = p_id) >= 3 then return false; end if;
  insert into public.copias (codigo_id, usuario_id) values (p_id, v_id) on conflict do nothing;
  return found;
end $$;

create or replace function public.apagar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  delete from public.codigos
  where id = p_id and autor_id = (auth.jwt() ->> 'sub')
    and not exists (select 1 from public.copias where codigo_id = p_id);
  return found;
end $$;

-- ---------------------------------------------------------------------
-- 9. Permissões
-- ---------------------------------------------------------------------
revoke all on function public.eh_membro(), public.eh_admin(), public.entrar(),
  public.admin_alterar_acesso(text, text, text, timestamptz), public.definir_primeiro_admin(text),
  public.postar_codigos(text, text[]), public.copiar_codigo(bigint), public.apagar_codigo(bigint)
  from public, anon, authenticated;

grant execute on function public.eh_membro(), public.eh_admin(), public.entrar(),
  public.admin_alterar_acesso(text, text, text, timestamptz),
  public.postar_codigos(text, text[]), public.copiar_codigo(bigint), public.apagar_codigo(bigint)
  to authenticated;
-- definir_primeiro_admin: sem grant de propósito (só o dono do banco, no SQL Editor)

commit;
