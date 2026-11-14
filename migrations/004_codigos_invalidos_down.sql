-- =====================================================================
-- Reversão da migração 004 — volta às funções e à view da 003
--
-- NÃO apaga dados: relatos, bloqueios, eventos e as colunas de desativação
-- ficam guardados (para reaplicar a 004 depois sem perder nada). Enquanto a
-- 004 estiver revertida, porém, NADA disso tem efeito: códigos desativados
-- voltam a aparecer na lista, no lote e nas cópias, e combinações bloqueadas
-- podem ser republicadas.
--
-- Idempotente e seguro com comandos executados separadamente.
-- =====================================================================
begin;

-- view como na 001
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

-- postar_codigos() e copiar_codigo() como na 001
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

-- copiar_codigo_v2() como na 002
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

-- pegar_lote() como na 003
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
    -- 1. Trava todos os candidatos, sempre em ordem de id (dois lotes travam
    --    na mesma ordem: sem impasse). Espera em vez de pular: um código
    --    antigo ocupado por outra pessoa não é trocado por um mais novo.
    --    Não filtra por cópias aqui: a foto deste comando pode estar velha;
    --    a elegibilidade de verdade é decidida no passo 2.
    select coalesce(array_agg(t.id), '{}') into v_trav
      from (select c.id
              from public.codigos c
             where c.plataforma = p_plataforma
               and c.autor_id <> v_id
               and c.criado_em > now() - interval '48 hours'
             order by c.id
               for update of c) t;

    -- 2. Com tudo travado, este comando enxerga uma foto NOVA (tirada depois
    --    das travas). Toda cópia passa pela trava do código, então as
    --    contagens abaixo não mudam até o fim da transação.
    with elegiveis as (
      select c.id, c.criado_em,
             row_number() over (partition by c.autor_id order by c.criado_em, c.id) as nivel
        from public.codigos c
       where c.id = any (v_trav)
         and c.criado_em > now() - interval '48 hours'
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
    -- desfaz tudo deste bloco (nenhuma cópia parcial) e avisa o site
    raise exception 'lote_ocupado';
  end;

  if v_reg = 0 then
    return json_build_object('lote_id', null, 'pedidos', p_quantidade, 'registrados', 0,
                             'plataforma', p_plataforma, 'codigos', '[]'::json);
  end if;
  return public.resumo_lote(v_lote, p_quantidade);
end $$;

drop function if exists public.relatar_invalidos(text, text[]);
drop function if exists public.admin_codigos_invalidos();
drop function if exists public.admin_confirmar_invalido(text, text, text);
drop function if exists public.admin_reverter_invalido(text, text, text);

grant execute on function public.copiar_codigo(bigint), public.copiar_codigo_v2(bigint),
  public.pegar_lote(text, int), public.postar_codigos(text, text[]) to authenticated;
revoke all on function public.copiar_codigo(bigint), public.copiar_codigo_v2(bigint),
  public.pegar_lote(text, int), public.postar_codigos(text, text[]) from public, anon;
grant select on public.codigos_ativos to authenticated;
revoke insert, update, delete, truncate, references, trigger on public.codigos_ativos from authenticated;
revoke all on public.codigos_ativos from anon;

update public.migracoes set revertida_em = now() where versao = '004_codigos_invalidos';

commit;
