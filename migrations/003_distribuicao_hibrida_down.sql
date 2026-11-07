-- =====================================================================
-- Reversão da migração 003 — volta a pegar_lote() da 002
--
-- Não apaga nem altera dados: lotes e cópias feitos com a 003 continuam
-- válidos e recuperáveis (a 003 não mudou o formato de nada). Só o critério
-- de escolha volta a ser "mais perto de vencer primeiro" com SKIP LOCKED.
--
-- Idempotente e seguro com comandos executados separadamente.
-- =====================================================================
begin;

-- pegar_lote() exatamente como na migração 002
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

-- create or replace mantém os privilégios; mesmo assim reafirma, sem nunca
-- tirar o acesso de authenticated (nem por um instante, se o editor parar aqui)
grant execute on function public.pegar_lote(text, int) to authenticated;
revoke all on function public.pegar_lote(text, int) from public, anon;

update public.migracoes set revertida_em = now() where versao = '003_distribuicao_hibrida';

commit;
