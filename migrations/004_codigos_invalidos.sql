-- =====================================================================
-- Migração 004 — Relatos de códigos inválidos e desativação lógica
--
-- Pré-requisito: migração 003 aplicada (e não revertida).
--
-- ASSOCIAÇÃO do relato (quem relata cola só o texto do código):
--   * se a pessoa copiou EXATAMENTE UMA publicação daquele código (naquela
--     plataforma) pelo mural, o relato vai para ESSA publicação — mesmo que
--     exista uma republicação mais nova;
--   * copiou mais de uma (código republicado e pego duas vezes): vai para a
--     mais recente que ela copiou, marcado 'ambigua';
--   * não copiou nenhuma: vai para a publicação mais recente, 'sem_copia'.
--   Só conta para a suspensão automática ('qualificado') o relato 'copiada'
--   feito até 72 h depois da cópia. 'ambigua', 'sem_copia' e 'fora_do_prazo'
--   ficam registrados para o admin e nunca suspendem nada.
--
-- Regra (conservadora):
--   * 2 relatos qualificados de pessoas diferentes na MESMA publicação ->
--     SUSPENSÃO daquela publicação (sai da lista, do lote e das cópias).
--     Não bloqueia republicar; relatos de uma publicação nunca contam para
--     outra (uma republicação começa do zero).
--   * admin CONFIRMA uma publicação -> ela fica desativada ('admin') e a
--     combinação plataforma + código é BLOQUEADA: republicação recusada e as
--     outras publicações ainda ativas dela são desativadas ('bloqueio').
--   * admin DESBLOQUEIA a combinação -> libera republicar e reativa SÓ as
--     publicações desativadas pelo bloqueio; as suspensas por relatos ou
--     confirmadas continuam desativadas (motivos independentes).
--   * admin REATIVA uma publicação específica -> só ela; descarta os relatos
--     dela (recusado enquanto a combinação estiver bloqueada).
--   Toda mudança de estado vai para eventos_invalidos, com o estado anterior.
--
-- Desativação lógica: nada é apagado; cópias, lotes e recuperação continuam
-- íntegros. Ranking inalterado (postados/aproveitados são históricos; "ativos"
-- vem da view codigos_ativos, que passa a ignorar os desativados).
--
-- Caminhos filtrados NO BANCO: codigos_ativos, copiar_codigo (v1),
-- copiar_codigo_v2 (status novo 'invalidado'), pegar_lote (só o filtro; a
-- distribuição da 003 não muda) e postar_codigos (devolve 'bloqueados').
--
-- Travas: quem desativa trava a linha do código (como as cópias); quem trava
-- várias linhas trava em ordem de id (como o lote) -> sem impasse. Ações do
-- admin e publicação usam a mesma trava por plataforma da postar_codigos.
--
-- Seguro no SQL Editor com comandos separados: sem tabela temporária, tudo
-- idempotente; primeira aplicação x reaplicação lida de public.migracoes.
-- Como aplicar e reverter: docs/IMPLANTACAO.md, seção "Migração 004".
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 0. Pré-requisito
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.migracoes where versao = '003_distribuicao_hibrida' and revertida_em is null) then
    raise exception 'A migração 003_distribuicao_hibrida precisa estar aplicada antes da 004.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Estrutura (aditiva)
-- ---------------------------------------------------------------------
alter table public.codigos add column if not exists desativado_em timestamptz;
alter table public.codigos add column if not exists desativacao text;
alter table public.codigos drop constraint if exists codigos_desativacao_check;
alter table public.codigos add constraint codigos_desativacao_check
  check ((desativado_em is null and desativacao is null)
      or (desativado_em is not null and desativacao in ('relatos', 'admin', 'bloqueio')));

create table if not exists public.relatos_invalidos (
  id             bigint generated always as identity primary key,
  codigo_id      bigint references public.codigos(id) on delete set null,
  plataforma     text not null,
  codigo         text not null,
  usuario_id     text not null references public.usuarios(id),
  associacao     text not null,                -- copiada | fora_do_prazo | ambigua | sem_copia
  qualificado    boolean not null,             -- conta para a suspensão (= associacao 'copiada')
  copia_em       timestamptz,                  -- quando quem relatou copiou essa publicação
  criado_em      timestamptz not null default now(),
  descartado_em  timestamptz,                  -- admin reativou/descartou: deixa de contar
  descartado_por text references public.usuarios(id),
  unique (codigo_id, usuario_id)
);
alter table public.relatos_invalidos drop constraint if exists relatos_invalidos_associacao_check;
alter table public.relatos_invalidos add constraint relatos_invalidos_associacao_check
  check (associacao in ('copiada', 'fora_do_prazo', 'ambigua', 'sem_copia') and qualificado = (associacao = 'copiada'));
create index if not exists relatos_codigo on public.relatos_invalidos (codigo_id) where descartado_em is null;

create table if not exists public.codigos_bloqueados (
  plataforma    text not null,
  codigo        text not null,
  bloqueado_em  timestamptz not null default now(),
  bloqueado_por text not null references public.usuarios(id),
  motivo        text,
  primary key (plataforma, codigo)
);

create table if not exists public.eventos_invalidos (
  id              bigint generated always as identity primary key,
  plataforma      text not null,
  codigo          text not null,
  codigo_id       bigint,                       -- null = a combinação toda (bloqueio)
  acao            text not null,
  estado_anterior text,                         -- ativo | relatos | admin | bloqueio | bloqueado
  por_id          text references public.usuarios(id),   -- null = automático
  motivo          text,
  criado_em       timestamptz not null default now()
);
alter table public.eventos_invalidos drop constraint if exists eventos_invalidos_acao_check;
alter table public.eventos_invalidos add constraint eventos_invalidos_acao_check
  check (acao in ('suspenso_automatico', 'confirmado', 'desativado_por_bloqueio', 'desbloqueado',
                  'reativado_por_desbloqueio', 'reativado', 'relatos_descartados'));

-- sem acesso direto: só pelas funções abaixo (RLS ligado e nenhuma política)
alter table public.relatos_invalidos  enable row level security;
alter table public.codigos_bloqueados enable row level security;
alter table public.eventos_invalidos  enable row level security;
revoke all on public.relatos_invalidos, public.codigos_bloqueados, public.eventos_invalidos from anon, authenticated;

-- ---------------------------------------------------------------------
-- 2. Leitura: desativados saem da view (lista, contadores, ranking.ativos)
-- ---------------------------------------------------------------------
create or replace view public.codigos_ativos with (security_invoker = true) as
select c.id, c.plataforma, c.codigo, c.autor_id, u.nome as autor, c.criado_em,
       count(cp.usuario_id)::int as copias,
       coalesce(array_agg(cp.usuario_id) filter (where cp.usuario_id is not null), '{}') as copiado_por
from public.codigos c
join public.usuarios u on u.id = c.autor_id
left join public.copias cp on cp.codigo_id = c.id
where c.criado_em > now() - interval '48 hours'
  and c.desativado_em is null
  and (select public.eh_membro())
group by c.id, u.nome
having count(cp.usuario_id) < 3;

-- ---------------------------------------------------------------------
-- 3. Escrita: cópias, lote e publicação recusam desativados/bloqueados
-- ---------------------------------------------------------------------
create or replace function public.copiar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_id text := auth.jwt() ->> 'sub';
  v_c  public.codigos%rowtype;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  select * into v_c from public.codigos where id = p_id for update;
  if not found or v_c.autor_id = v_id or v_c.criado_em <= now() - interval '48 hours'
     or v_c.desativado_em is not null then return false; end if;
  if (select count(*) from public.copias where codigo_id = p_id) >= 3 then return false; end if;
  insert into public.copias (codigo_id, usuario_id) values (p_id, v_id) on conflict do nothing;
  return found;
end $$;

-- ordem: inexistente -> invalidado -> expirado -> proprio -> ja_copiado -> esgotado -> registrado
create or replace function public.copiar_codigo_v2(p_id bigint)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id text := auth.jwt() ->> 'sub';
  v_c  public.codigos%rowtype;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;

  select * into v_c from public.codigos where id = p_id for update;
  if not found then
    return json_build_object('status', 'inexistente');
  end if;
  if v_c.desativado_em is not null then
    return json_build_object('status', 'invalidado');
  end if;
  if v_c.criado_em <= now() - interval '48 hours' then
    return json_build_object('status', 'expirado');
  end if;
  if v_c.autor_id = v_id then
    return json_build_object('status', 'proprio', 'codigo', v_c.codigo);
  end if;
  if exists (select 1 from public.copias where codigo_id = p_id and usuario_id = v_id) then
    return json_build_object('status', 'ja_copiado', 'codigo', v_c.codigo);
  end if;
  if (select count(*) from public.copias where codigo_id = p_id) >= 3 then
    return json_build_object('status', 'esgotado');
  end if;

  insert into public.copias (codigo_id, usuario_id) values (p_id, v_id);
  return json_build_object('status', 'registrado', 'codigo', v_c.codigo);
end $$;

-- pegar_lote() da 003 com UMA condição a mais (c.desativado_em is null);
-- critério de distribuição, travas e resposta idênticos
create or replace function public.pegar_lote(p_plataforma text, p_quantidade int)
returns json language plpgsql security definer
set search_path = '' set lock_timeout = '5s' as $$
declare
  v_id   text := auth.jwt() ->> 'sub';
  v_lote uuid := gen_random_uuid();
  v_reg  int := 0;
  v_trav bigint[];
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  if p_quantidade is null or p_quantidade < 1 or p_quantidade > 200 then
    raise exception 'quantidade_invalida';
  end if;

  begin
    select coalesce(array_agg(t.id), '{}') into v_trav
      from (select c.id
              from public.codigos c
             where c.plataforma = p_plataforma
               and c.autor_id <> v_id
               and c.criado_em > now() - interval '48 hours'
             order by c.id
               for update of c) t;

    with elegiveis as (
      select c.id, c.criado_em,
             row_number() over (partition by c.autor_id order by c.criado_em, c.id) as nivel
        from public.codigos c
       where c.id = any (v_trav)
         and c.criado_em > now() - interval '48 hours'
         and c.desativado_em is null
         and not exists (select 1 from public.copias x where x.codigo_id = c.id and x.usuario_id = v_id)
         and (select count(*) from public.copias x where x.codigo_id = c.id) < 3
    )
    insert into public.copias (codigo_id, usuario_id, lote_id)
    select e.id, v_id, v_lote
      from elegiveis e
     order by e.nivel, e.criado_em, e.id
     limit p_quantidade;
    get diagnostics v_reg = row_count;
  exception when lock_not_available then
    raise exception 'lote_ocupado';
  end;

  if v_reg = 0 then
    return json_build_object('lote_id', null, 'pedidos', p_quantidade, 'registrados', 0,
                             'plataforma', p_plataforma, 'codigos', '[]'::json);
  end if;
  return public.resumo_lote(v_lote, p_quantidade);
end $$;

-- postar: mesma regra de repetidos (48 h) + recusa combinações bloqueadas
create or replace function public.postar_codigos(p_plataforma text, p_codigos text[])
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id   text := auth.jwt() ->> 'sub';
  v_cod  text;
  v_add  int := 0;
  v_rep  text[] := '{}';
  v_bloq text[] := '{}';
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  if coalesce(array_length(p_codigos, 1), 0) > 200 then raise exception 'maximo_200_por_vez'; end if;
  perform pg_advisory_xact_lock(hashtext('postar:' || p_plataforma));
  foreach v_cod in array (select array(select distinct unnest(p_codigos))) loop
    if exists (select 1 from public.codigos_bloqueados b where b.plataforma = p_plataforma and b.codigo = v_cod) then
      v_bloq := v_bloq || v_cod;
    elsif exists (select 1 from public.codigos c
                  where c.plataforma = p_plataforma and c.codigo = v_cod
                    and c.criado_em > now() - interval '48 hours') then
      v_rep := v_rep || v_cod;
    else
      insert into public.codigos (plataforma, codigo, autor_id) values (p_plataforma, v_cod, v_id);
      v_add := v_add + 1;
    end if;
  end loop;
  return json_build_object('adicionados', v_add, 'repetidos', v_rep, 'bloqueados', v_bloq);
end $$;

-- ---------------------------------------------------------------------
-- 4. Relatar inválidos (membros)
-- ---------------------------------------------------------------------
create or replace function public.relatar_invalidos(p_plataforma text, p_codigos text[])
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id      text := auth.jwt() ->> 'sub';
  v_lista   text[];
  v_validos text[];
  v_alvo    record;
  v_c       public.codigos%rowtype;
  v_assoc   text;
  v_copia   timestamptz;
  v_qualif  int;
  r_formato int := 0; r_nao int := 0; r_prop int := 0; r_desat int := 0;
  r_ja int := 0; r_rep int := 0; r_naoconta int := 0; r_susp int := 0; r_encontrados int := 0;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  if p_plataforma is null or p_plataforma not in ('777', 'BRA365', 'Sorte25', '77') then
    raise exception 'plataforma_invalida';
  end if;
  -- normaliza: tira espaços, descarta vazios, remove duplicatas
  v_lista := array(select distinct btrim(x) from unnest(coalesce(p_codigos, '{}')) x where btrim(x) <> '');
  if coalesce(array_length(v_lista, 1), 0) = 0 then raise exception 'lista_vazia'; end if;
  if array_length(v_lista, 1) > 500 then raise exception 'maximo_500_por_vez'; end if;

  v_validos := array(select x from unnest(v_lista) x where x ~ '^[A-Za-z0-9_-]{2,64}$');
  r_formato := array_length(v_lista, 1) - coalesce(array_length(v_validos, 1), 0);

  -- uma publicação-alvo por código: a que ESTA pessoa copiou (se foi uma só);
  -- processadas em ordem de id (mesma ordem de trava do lote: sem impasse)
  for v_alvo in
    with pubs as (
      select c.id, c.codigo,
             exists (select 1 from public.copias p where p.codigo_id = c.id and p.usuario_id = v_id) as copiei
        from public.codigos c
       where c.plataforma = p_plataforma and c.codigo = any (v_validos)
    ), por_codigo as (
      select count(*) filter (where copiei) as n_copiadas,
             max(id) filter (where copiei) as copiada_mais_recente,
             max(id) as mais_recente
        from pubs group by codigo
    )
    select coalesce(copiada_mais_recente, mais_recente) as id,
           case when n_copiadas = 0 then 'sem_copia' when n_copiadas > 1 then 'ambigua' else 'copiada' end as assoc
      from por_codigo
     order by 1
  loop
    select * into v_c from public.codigos where id = v_alvo.id for update;
    if not found then continue; end if;                     -- apagada no meio: conta como não encontrado
    r_encontrados := r_encontrados + 1;
    if v_c.autor_id = v_id then r_prop := r_prop + 1; continue; end if;
    if v_c.desativado_em is not null
       or exists (select 1 from public.codigos_bloqueados b where b.plataforma = v_c.plataforma and b.codigo = v_c.codigo) then
      r_desat := r_desat + 1; continue;
    end if;

    -- com a linha travada: confere a cópia de novo e o prazo de 72 h
    v_copia := (select p.criado_em from public.copias p where p.codigo_id = v_c.id and p.usuario_id = v_id);
    v_assoc := case when v_alvo.assoc <> 'copiada' then v_alvo.assoc
                    when v_copia is null then 'sem_copia'
                    when v_copia <= now() - interval '72 hours' then 'fora_do_prazo'
                    else 'copiada' end;

    insert into public.relatos_invalidos (codigo_id, plataforma, codigo, usuario_id, associacao, qualificado, copia_em)
    values (v_c.id, v_c.plataforma, v_c.codigo, v_id, v_assoc, v_assoc = 'copiada', v_copia)
    on conflict (codigo_id, usuario_id) do nothing;
    if not found then r_ja := r_ja + 1; continue; end if;
    r_rep := r_rep + 1;
    if v_assoc <> 'copiada' then r_naoconta := r_naoconta + 1; continue; end if;

    -- 2 relatos qualificados NESTA publicação (pessoas diferentes: unique) -> suspende
    select count(*) into v_qualif from public.relatos_invalidos
     where codigo_id = v_c.id and qualificado and descartado_em is null;
    if v_qualif >= 2 then
      update public.codigos set desativado_em = now(), desativacao = 'relatos' where id = v_c.id;
      insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, motivo)
      values (v_c.plataforma, v_c.codigo, v_c.id, 'suspenso_automatico', 'ativo', v_qualif || ' relatos qualificados');
      r_susp := r_susp + 1;
    end if;
  end loop;

  r_nao := coalesce(array_length(v_validos, 1), 0) - r_encontrados;
  return json_build_object(
    'plataforma', p_plataforma,
    'recebidos', array_length(v_lista, 1),
    'formato_invalido', r_formato,
    'encontrados', r_encontrados,
    'nao_encontrados', r_nao,
    'reportados', r_rep,
    'nao_contam', r_naoconta,          -- reportados que não contam para a suspensão
    'ja_reportados', r_ja,
    'ja_desativados', r_desat,
    'proprios', r_prop,
    'suspensos_agora', r_susp);
end $$;

-- ---------------------------------------------------------------------
-- 5. Administração: revisar, confirmar, desbloquear e reativar
-- ---------------------------------------------------------------------
-- versões anteriores desta branch (nunca publicadas): assinaturas por texto
drop function if exists public.admin_confirmar_invalido(text, text, text);
drop function if exists public.admin_reverter_invalido(text, text, text);

create or replace function public.admin_codigos_invalidos()
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_admin() then raise exception 'acesso_negado'; end if;
  return json_build_object(
    -- publicações com relatos válidos ou desativadas (últimos 30 dias)
    'publicacoes', (select coalesce(json_agg(x order by x.ultimo_relato desc nulls last, x.codigo_id desc), '[]'::json) from (
      select c.id as codigo_id, c.plataforma, c.codigo, u.nome as autor, c.criado_em,
             c.criado_em > now() - interval '48 hours' as dentro_48h,
             (select count(*) from public.copias p where p.codigo_id = c.id)::int as copias,
             (select count(*) from public.relatos_invalidos r where r.codigo_id = c.id and r.descartado_em is null)::int as relatos,
             (select count(*) from public.relatos_invalidos r where r.codigo_id = c.id and r.descartado_em is null and r.qualificado)::int as qualificados,
             (select max(r.criado_em) from public.relatos_invalidos r where r.codigo_id = c.id and r.descartado_em is null) as ultimo_relato,
             c.desativado_em, c.desativacao,
             exists (select 1 from public.codigos_bloqueados b where b.plataforma = c.plataforma and b.codigo = c.codigo) as bloqueado
        from public.codigos c join public.usuarios u on u.id = c.autor_id
       where (c.desativado_em is not null
              or exists (select 1 from public.relatos_invalidos r where r.codigo_id = c.id and r.descartado_em is null))
         and c.criado_em > now() - interval '30 days') x),
    -- combinações bloqueadas (republicação impedida)
    'bloqueados', (select coalesce(json_agg(json_build_object('plataforma', b.plataforma, 'codigo', b.codigo,
                     'bloqueado_em', b.bloqueado_em, 'por', u.nome, 'motivo', b.motivo) order by b.bloqueado_em desc), '[]'::json)
                     from public.codigos_bloqueados b left join public.usuarios u on u.id = b.bloqueado_por),
    -- auditoria recente
    'eventos', (select coalesce(json_agg(e order by e.id desc), '[]'::json) from (
      select ev.id, ev.plataforma, ev.codigo, ev.codigo_id, ev.acao, ev.estado_anterior, ev.motivo, ev.criado_em, u.nome as por
        from public.eventos_invalidos ev left join public.usuarios u on u.id = ev.por_id
       order by ev.id desc limit 50) e));
end $$;

-- confirma UMA publicação como inválida e bloqueia a combinação
create or replace function public.admin_confirmar_invalido(p_codigo_id bigint, p_motivo text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id    text := auth.jwt() ->> 'sub';
  v_c     public.codigos%rowtype;
  v_mot   text := nullif(btrim(p_motivo), '');
  v_outra record;
  v_n     int := 0;
begin
  if not public.eh_admin() then raise exception 'acesso_negado'; end if;
  select * into v_c from public.codigos where id = p_codigo_id;
  if not found then raise exception 'codigo_inexistente'; end if;
  -- mesma trava da postar_codigos (ninguém republica no meio); depois as
  -- publicações da combinação em ordem de id (como o lote)
  perform pg_advisory_xact_lock(hashtext('postar:' || v_c.plataforma));
  perform 1 from public.codigos where plataforma = v_c.plataforma and codigo = v_c.codigo order by id for update;
  select * into v_c from public.codigos where id = p_codigo_id;
  if not found then raise exception 'codigo_inexistente'; end if;

  if v_c.desativacao = 'admin'
     and exists (select 1 from public.codigos_bloqueados b where b.plataforma = v_c.plataforma and b.codigo = v_c.codigo) then
    return json_build_object('status', 'ja_confirmado', 'desativados_pelo_bloqueio', 0);
  end if;

  update public.codigos set desativado_em = coalesce(desativado_em, now()), desativacao = 'admin' where id = v_c.id;
  insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, por_id, motivo)
  values (v_c.plataforma, v_c.codigo, v_c.id, 'confirmado', coalesce(v_c.desativacao, 'ativo'), v_id, v_mot);

  insert into public.codigos_bloqueados (plataforma, codigo, bloqueado_por, motivo)
  values (v_c.plataforma, v_c.codigo, v_id, v_mot)
  on conflict (plataforma, codigo) do nothing;

  -- outras publicações ainda ativas da mesma combinação: desativadas PELO BLOQUEIO
  for v_outra in
    update public.codigos set desativado_em = now(), desativacao = 'bloqueio'
     where plataforma = v_c.plataforma and codigo = v_c.codigo and id <> v_c.id and desativado_em is null
    returning id
  loop
    insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, por_id, motivo)
    values (v_c.plataforma, v_c.codigo, v_outra.id, 'desativado_por_bloqueio', 'ativo', v_id, v_mot);
    v_n := v_n + 1;
  end loop;
  return json_build_object('status', 'confirmado', 'desativados_pelo_bloqueio', v_n);
end $$;

-- libera a republicação; reativa SÓ o que foi desativado pelo bloqueio
create or replace function public.admin_desbloquear_codigo(p_plataforma text, p_codigo text, p_motivo text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id    text := auth.jwt() ->> 'sub';
  v_mot   text := nullif(btrim(p_motivo), '');
  v_pub   record;
  v_n     int := 0;
begin
  if not public.eh_admin() then raise exception 'acesso_negado'; end if;
  if p_plataforma is null or p_plataforma not in ('777', 'BRA365', 'Sorte25', '77') then raise exception 'plataforma_invalida'; end if;
  perform pg_advisory_xact_lock(hashtext('postar:' || p_plataforma));
  perform 1 from public.codigos where plataforma = p_plataforma and codigo = p_codigo order by id for update;

  delete from public.codigos_bloqueados where plataforma = p_plataforma and codigo = p_codigo;
  if not found then return json_build_object('status', 'nao_bloqueado'); end if;
  insert into public.eventos_invalidos (plataforma, codigo, acao, estado_anterior, por_id, motivo)
  values (p_plataforma, p_codigo, 'desbloqueado', 'bloqueado', v_id, v_mot);

  for v_pub in
    update public.codigos set desativado_em = null, desativacao = null
     where plataforma = p_plataforma and codigo = p_codigo and desativacao = 'bloqueio'
    returning id
  loop
    insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, por_id, motivo)
    values (p_plataforma, p_codigo, v_pub.id, 'reativado_por_desbloqueio', 'bloqueio', v_id, v_mot);
    v_n := v_n + 1;
  end loop;
  return json_build_object('status', 'desbloqueado', 'reativados', v_n,
    'continuam_desativados', (select count(*) from public.codigos
                               where plataforma = p_plataforma and codigo = p_codigo and desativado_em is not null));
end $$;

-- reativa UMA publicação (ou só descarta os relatos dela, se estiver ativa)
create or replace function public.admin_reativar_publicacao(p_codigo_id bigint, p_motivo text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id  text := auth.jwt() ->> 'sub';
  v_mot text := nullif(btrim(p_motivo), '');
  v_c   public.codigos%rowtype;
  v_desc int;
begin
  if not public.eh_admin() then raise exception 'acesso_negado'; end if;
  select * into v_c from public.codigos where id = p_codigo_id;
  if not found then raise exception 'codigo_inexistente'; end if;
  perform pg_advisory_xact_lock(hashtext('postar:' || v_c.plataforma));
  select * into v_c from public.codigos where id = p_codigo_id for update;
  if not found then raise exception 'codigo_inexistente'; end if;
  if exists (select 1 from public.codigos_bloqueados b where b.plataforma = v_c.plataforma and b.codigo = v_c.codigo) then
    raise exception 'codigo_bloqueado';          -- desbloqueie a combinação antes
  end if;

  update public.relatos_invalidos set descartado_em = now(), descartado_por = v_id
   where codigo_id = v_c.id and descartado_em is null;
  get diagnostics v_desc = row_count;

  if v_c.desativado_em is not null then
    update public.codigos set desativado_em = null, desativacao = null where id = v_c.id;
    insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, por_id, motivo)
    values (v_c.plataforma, v_c.codigo, v_c.id, 'reativado', v_c.desativacao, v_id, v_mot);
    return json_build_object('status', 'reativado', 'estado_anterior', v_c.desativacao, 'relatos_descartados', v_desc);
  end if;
  if v_desc = 0 then return json_build_object('status', 'nada_a_reverter'); end if;
  insert into public.eventos_invalidos (plataforma, codigo, codigo_id, acao, estado_anterior, por_id, motivo)
  values (v_c.plataforma, v_c.codigo, v_c.id, 'relatos_descartados', 'ativo', v_id, v_mot);
  return json_build_object('status', 'relatos_descartados', 'relatos_descartados', v_desc);
end $$;

-- ---------------------------------------------------------------------
-- 6. Permissões de funções
-- ---------------------------------------------------------------------
-- create or replace mantém os privilégios das funções existentes; reafirma
-- sem nunca tirar o acesso de authenticated
grant execute on function public.copiar_codigo(bigint), public.copiar_codigo_v2(bigint),
  public.pegar_lote(text, int), public.postar_codigos(text, text[]),
  public.relatar_invalidos(text, text[]), public.admin_codigos_invalidos(),
  public.admin_confirmar_invalido(bigint, text), public.admin_desbloquear_codigo(text, text, text),
  public.admin_reativar_publicacao(bigint, text)
  to authenticated;
revoke all on function public.copiar_codigo(bigint), public.copiar_codigo_v2(bigint),
  public.pegar_lote(text, int), public.postar_codigos(text, text[]),
  public.relatar_invalidos(text, text[]), public.admin_codigos_invalidos(),
  public.admin_confirmar_invalido(bigint, text), public.admin_desbloquear_codigo(text, text, text),
  public.admin_reativar_publicacao(bigint, text)
  from public, anon;
-- view recriada (create or replace mantém os privilégios): reafirma só leitura,
-- sem retirar o select de authenticated nem por um instante
grant select on public.codigos_ativos to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.codigos_ativos from authenticated;
revoke all on public.codigos_ativos from anon;

-- ---------------------------------------------------------------------
-- 7. Registro e resumo (último passo)
-- ---------------------------------------------------------------------
insert into public.migracoes (versao) values ('004_codigos_invalidos')
on conflict (versao) do update
  set ultima_aplicacao = now(), aplicacoes = public.migracoes.aplicacoes + 1, revertida_em = null;

do $$
declare
  v_aplicacoes int := (select aplicacoes from public.migracoes where versao = '004_codigos_invalidos');
begin
  if v_aplicacoes = 1 then
    raise notice 'MIGRAÇÃO 004 APLICADA: relatos de inválidos e desativação lógica; nenhum código, cópia ou lote alterado.';
  else
    raise notice 'MIGRAÇÃO 004 REAPLICADA (execução nº %): funções atualizadas; relatos, bloqueios e desativações mantidos.', v_aplicacoes;
  end if;
end $$;

commit;
