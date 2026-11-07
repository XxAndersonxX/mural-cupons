-- =====================================================================
-- Reversão da migração 002 — volta ao comportamento da 001
--
-- Não apaga dados: as cópias continuam todas lá. A coluna copias.lote_id
-- fica no banco (sem uso). A seção "LIMPEZA OPCIONAL" no final remove a
-- coluna — isso descarta só a informação de qual cópia pertencia a qual lote.
-- =====================================================================
begin;

-- A 003 depende da pegar_lote() desta migração: reverta a 003 primeiro.
do $$
begin
  if exists (select 1 from public.migracoes where versao = '003_distribuicao_hibrida' and revertida_em is null) then
    raise exception 'Reverta a migração 003 antes (003_distribuicao_hibrida_down.sql). Nada foi alterado.';
  end if;
end $$;

drop function if exists public.copiar_codigo_v2(bigint);
drop function if exists public.pegar_lote(text, int);
drop function if exists public.recuperar_lote(uuid);
drop function if exists public.meus_lotes();
drop function if exists public.resumo_lote(uuid, int);

-- ranking como na 001 (remover coluna de view exige recriar a view)
drop view if exists public.ranking;
create view public.ranking with (security_invoker = true) as
select u.id, u.nome, u.criado_em,
       (select count(*) from public.codigos c where c.autor_id = u.id)::int as postados,
       (select count(*) from public.copias  p where p.usuario_id = u.id)::int as copiados,
       (select count(*) from public.codigos_ativos a where a.autor_id = u.id)::int as ativos
from public.usuarios u
where (select public.eh_membro())
  and u.papel in ('membro', 'admin') and u.situacao = 'ativo';
revoke all on public.ranking from anon, authenticated;
grant select on public.ranking to authenticated;

update public.migracoes set revertida_em = now() where versao = '002_copias_ranking';

commit;

-- ---------------------------------------------------------------------
-- LIMPEZA OPCIONAL (descarta só a informação de lote). Só se tiver certeza.
-- ---------------------------------------------------------------------
-- begin;
-- drop index if exists public.copias_usuario_lote;
-- drop index if exists public.copias_lote;
-- alter table public.copias drop column if exists lote_id;
-- commit;
