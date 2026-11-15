-- =====================================================================
-- Migração 003 — Distribuição híbrida do lote
--
-- Pré-requisito: migração 002 aplicada (e não revertida).
--
-- Troca SÓ o critério de escolha da pegar_lote(): mesmo nome, mesmos
-- parâmetros, mesmo formato de resposta, mesmas permissões. Não cria nem
-- altera tabelas, colunas, views ou dados. Nenhuma outra função muda.
--
-- Critério (aprovado na Fase 3):
--   Cada código elegível recebe um NÍVEL = sua posição na fila do próprio
--   autor (o mais antigo do autor é o nível 1, o seguinte o nível 2...).
--   O lote leva os N primeiros na ordem (nível, criado_em, id). Resultado:
--     * divisão igual entre os autores; quem tem menos que a sua parte
--       entrega tudo e a sobra vai para os demais;
--     * a sobra que não divide igual vai para os autores cujo PRÓXIMO
--       código é o mais antigo (depois, menor id);
--     * dentro de cada autor, sempre do mais antigo para o mais novo.
--   A lista devolvida continua em ordem global de vencimento (resumo_lote):
--   o equilíbrio define QUAIS códigos entram, não a ordem de apresentação.
--
-- Concorrência (substitui o SKIP LOCKED da 002):
--   1. trava TODOS os códigos candidatos da plataforma (não próprios, dentro
--      das 48 h) em ordem de id, esperando quem estiver usando — sem pular;
--   2. só depois recalcula a elegibilidade com leitura nova e registra tudo
--      num único INSERT, restrito aos códigos travados;
--   3. espera no máximo 5 s (lock_timeout); passou disso, nada é registrado
--      e a resposta é o erro 'lote_ocupado' ("tente de novo").
--
-- Como aplicar e reverter: docs/IMPLANTACAO.md, seção "Migração 003".
--
-- Seguro no SQL Editor mesmo executando cada comando separadamente: sem
-- tabela temporária nem estado de sessão; todos os comandos idempotentes;
-- primeira aplicação x reaplicação lida de public.migracoes.
-- =====================================================================
begin;

-- ---------------------------------------------------------------------
-- 0. Pré-requisito
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from public.migracoes where versao = '002_copias_ranking' and revertida_em is null) then
    raise exception 'A migração 002_copias_ranking precisa estar aplicada antes da 003.';
  end if;
  if exists (select 1 from public.migracoes where versao = '004_codigos_invalidos' and revertida_em is null) then
    raise exception 'A migração 004 está ativa: reaplicar a 003 desfaria os filtros de códigos inválidos. Reverta a 004 antes (004_codigos_invalidos_down.sql), reaplique a 003 e depois a 004. Nada foi alterado.';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. Pegar lote com distribuição híbrida
-- ---------------------------------------------------------------------
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

-- ---------------------------------------------------------------------
-- 2. Permissões (iguais às da 002)
-- ---------------------------------------------------------------------
-- create or replace mantém os privilégios; mesmo assim reafirma, sem nunca
-- tirar o acesso de authenticated (nem por um instante, se o editor parar aqui)
grant execute on function public.pegar_lote(text, int) to authenticated;
revoke all on function public.pegar_lote(text, int) from public, anon;

-- ---------------------------------------------------------------------
-- 3. Registro e resumo (último passo: se o registro existe, tudo antes
--    dele foi aplicado)
-- ---------------------------------------------------------------------
insert into public.migracoes (versao) values ('003_distribuicao_hibrida')
on conflict (versao) do update
  set ultima_aplicacao = now(), aplicacoes = public.migracoes.aplicacoes + 1, revertida_em = null;

do $$
declare
  v_aplicacoes int := (select aplicacoes from public.migracoes where versao = '003_distribuicao_hibrida');
begin
  if v_aplicacoes = 1 then
    raise notice 'MIGRAÇÃO 003 APLICADA: pegar_lote() com distribuição híbrida; nenhum dado alterado.';
  else
    raise notice 'MIGRAÇÃO 003 REAPLICADA (execução nº %): pegar_lote() atualizada; nenhum dado alterado.', v_aplicacoes;
  end if;
end $$;

commit;
