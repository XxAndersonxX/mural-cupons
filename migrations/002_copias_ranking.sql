-- =====================================================================
-- Migração 002 — Cópia individual com motivo, cópia em lote, recuperação
--                de lotes e estatística de códigos aproveitados
--
-- Pré-requisito: migração 001 aplicada (e não revertida).
--
-- NÃO altera as regras existentes (48 horas, até 3 pessoas distintas, uma
-- cópia por pessoa, autor não conta). Todas as funções novas usam a mesma
-- trava por código (FOR UPDATE na linha de public.codigos) que a
-- copiar_codigo() já usa, então as três funções se coordenam entre si.
--
-- Aditivo e não destrutivo:
--   * copias ganha lote_id (uuid, opcional): identifica as cópias de um lote
--   * copiar_codigo_v2(id)       -> {status, codigo}
--   * pegar_lote(plataforma, n)  -> {lote_id, pedidos, registrados, codigos[]}
--   * recuperar_lote(lote_id)    -> mesma forma, SÓ leitura (não registra nada)
--   * meus_lotes()               -> meus lotes das últimas 48 horas
--   * ranking ganha a coluna aproveitados (no fim; ordenação inalterada)
--   * copiar_codigo() antiga continua existindo (compatibilidade)
--
-- Como aplicar e reverter: docs/IMPLANTACAO.md, seção "Migração 002".
--
-- Seguro no SQL Editor do Supabase mesmo que ele execute cada comando numa
-- transação/conexão separada: não usa tabela temporária nem estado de sessão,
-- e todo comando é idempotente (rodar o arquivo de novo depois de uma falha
-- no meio completa o que faltou). A primeira aplicação x reaplicação é lida
-- da tabela persistente public.migracoes.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 0. Pré-requisito
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.migracoes where versao = '001_membros' and revertida_em is null) then
    raise exception 'A migração 001_membros precisa estar aplicada antes da 002.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Identificador de lote nas cópias (aditivo)
-- ---------------------------------------------------------------------
alter table public.copias add column if not exists lote_id uuid;
create index if not exists copias_usuario_lote on public.copias (usuario_id, criado_em desc) where lote_id is not null;
create index if not exists copias_lote on public.copias (lote_id) where lote_id is not null;

-- ---------------------------------------------------------------------
-- 2. Cópia individual com motivo
--    Mesmas regras e mesma trava da copiar_codigo(); só informa o porquê.
--    Ordem das verificações:
--      inexistente -> expirado -> proprio -> ja_copiado -> esgotado -> registrado
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 3. Lote: monta a resposta a partir do que está GRAVADO (usada pelas duas
--    funções abaixo, para pegar e recuperar devolverem exatamente o mesmo)
-- ---------------------------------------------------------------------
create or replace function public.resumo_lote(p_lote uuid, p_pedidos int)
returns json language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'lote_id', p_lote,
    'pedidos', p_pedidos,
    'registrados', count(*),
    'plataforma', min(c.plataforma),
    'criado_em', min(p.criado_em),
    'codigos', coalesce(json_agg(json_build_object(
                  'id', c.id, 'codigo', c.codigo, 'vence_em', c.criado_em + interval '48 hours')
                ORDER BY c.criado_em, c.id), '[]'::json))
  from public.copias p
  join public.codigos c on c.id = p.codigo_id
  where p.lote_id = p_lote;
$$;

-- ---------------------------------------------------------------------
-- 4. Pegar lote: seleciona, trava, reconfere e registra numa transação
-- ---------------------------------------------------------------------
create or replace function public.pegar_lote(p_plataforma text, p_quantidade int)
returns json language plpgsql security definer set search_path = '' as $$
declare
  v_id   text := auth.jwt() ->> 'sub';
  v_lote uuid := gen_random_uuid();
  v_reg  int := 0;
  v_cand record;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  if p_quantidade is null or p_quantidade < 1 or p_quantidade > 200 then
    raise exception 'quantidade_invalida';
  end if;

  -- Candidatos: mais perto de vencer primeiro. SKIP LOCKED pula códigos que
  -- outra pessoa está registrando neste instante (o lote pode vir menor).
  for v_cand in
    select c.id
      from public.codigos c
     where c.plataforma = p_plataforma
       and c.autor_id <> v_id
       and c.criado_em > now() - interval '48 hours'
       and not exists (select 1 from public.copias x where x.codigo_id = c.id and x.usuario_id = v_id)
       and (select count(*) from public.copias x where x.codigo_id = c.id) < 3
     order by c.criado_em, c.id
     for update of c skip locked
  loop
    -- Reconferência com leitura nova, já com o código travado: o filtro acima
    -- usa a foto do início do comando e pode estar desatualizado.
    continue when (select count(*) from public.copias where codigo_id = v_cand.id) >= 3;
    continue when exists (select 1 from public.copias where codigo_id = v_cand.id and usuario_id = v_id);

    insert into public.copias (codigo_id, usuario_id, lote_id) values (v_cand.id, v_id, v_lote);
    v_reg := v_reg + 1;
    exit when v_reg >= p_quantidade;
  end loop;

  if v_reg = 0 then
    return json_build_object('lote_id', null, 'pedidos', p_quantidade, 'registrados', 0,
                             'plataforma', p_plataforma, 'codigos', '[]'::json);
  end if;
  return public.resumo_lote(v_lote, p_quantidade);
end $$;

-- ---------------------------------------------------------------------
-- 5. Recuperação: só leitura, só os próprios lotes, só últimas 48 horas.
--    Códigos apagados somem do lote (a cópia é apagada junto).
-- ---------------------------------------------------------------------
create or replace function public.recuperar_lote(p_lote uuid default null)
returns json language plpgsql stable security definer set search_path = '' as $$
declare
  v_id   text := auth.jwt() ->> 'sub';
  v_lote uuid;
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;

  select p.lote_id into v_lote
    from public.copias p
   where p.usuario_id = v_id
     and p.lote_id is not null
     and (p_lote is null or p.lote_id = p_lote)
     and p.criado_em > now() - interval '48 hours'
   order by p.criado_em desc
   limit 1;

  if v_lote is null then raise exception 'lote_nao_encontrado'; end if;
  return public.resumo_lote(v_lote, null);
end $$;

create or replace function public.meus_lotes()
returns json language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  return (
    select coalesce(json_agg(l ORDER BY l.criado_em desc), '[]'::json)
    from (
      select p.lote_id, min(c.plataforma) as plataforma, count(*)::int as registrados, min(p.criado_em) as criado_em
        from public.copias p
        join public.codigos c on c.id = p.codigo_id
       where p.usuario_id = (auth.jwt() ->> 'sub')
         and p.lote_id is not null
         and p.criado_em > now() - interval '48 hours'
       group by p.lote_id
    ) l);
end $$;

-- ---------------------------------------------------------------------
-- 6. Ranking: coluna nova "aproveitados" no fim (ordenação não muda)
--    = códigos do autor que receberam ao menos uma cópia de OUTRA pessoa;
--      um código pego por 3 pessoas conta 1.
-- ---------------------------------------------------------------------
create or replace view public.ranking with (security_invoker = true) as
select u.id, u.nome, u.criado_em,
       (select count(*) from public.codigos c where c.autor_id = u.id)::int as postados,
       (select count(*) from public.copias  p where p.usuario_id = u.id)::int as copiados,
       (select count(*) from public.codigos_ativos a where a.autor_id = u.id)::int as ativos,
       (select count(*) from public.codigos c
         where c.autor_id = u.id
           and exists (select 1 from public.copias p where p.codigo_id = c.id and p.usuario_id <> c.autor_id))::int as aproveitados
from public.usuarios u
where (select public.eh_membro())
  and u.papel in ('membro', 'admin') and u.situacao = 'ativo';

-- ---------------------------------------------------------------------
-- 7. Permissões (o Supabase concede "all" por padrão em objetos novos)
-- ---------------------------------------------------------------------
revoke all on public.ranking from anon, authenticated;
grant select on public.ranking to authenticated;
revoke all on public.copias from anon, authenticated;
grant select on public.copias to authenticated;

revoke all on function public.copiar_codigo_v2(bigint), public.pegar_lote(text, int),
  public.recuperar_lote(uuid), public.meus_lotes(), public.resumo_lote(uuid, int)
  from public, anon, authenticated;
grant execute on function public.copiar_codigo_v2(bigint), public.pegar_lote(text, int),
  public.recuperar_lote(uuid), public.meus_lotes()
  to authenticated;
-- resumo_lote: interna (sem grant), chamada só pelas funções acima

-- ---------------------------------------------------------------------
-- 8. Registro e resumo
-- ---------------------------------------------------------------------
insert into public.migracoes (versao) values ('002_copias_ranking')
on conflict (versao) do update
  set ultima_aplicacao = now(), aplicacoes = public.migracoes.aplicacoes + 1, revertida_em = null;

-- O registro acima é o último passo da migração: se ele existe, tudo antes
-- dele já foi aplicado. aplicacoes = 1 -> primeira vez; > 1 -> reaplicação.
do $$
declare
  v_aplicacoes int := (select aplicacoes from public.migracoes where versao = '002_copias_ranking');
begin
  if v_aplicacoes = 1 then
    raise notice 'MIGRAÇÃO 002 APLICADA: % cópia(s) existente(s) preservada(s) (sem lote).', (select count(*) from public.copias);
  else
    raise notice 'MIGRAÇÃO 002 REAPLICADA (execução nº %): funções e ranking atualizados; nenhuma cópia alterada.', v_aplicacoes;
  end if;
end $$;

commit;
