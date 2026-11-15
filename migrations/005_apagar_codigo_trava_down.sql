-- =====================================================================
-- Reversão da migração 005 — volta a apagar_codigo() da 001
--
-- ATENÇÃO: a versão da 001 tem a condição de corrida descrita na 005 (uma
-- exclusão simultânea a uma cópia pode apagar a cópia recém-confirmada).
-- Reverter só se a 005 causar algum problema. Não altera dados.
-- Idempotente e seguro com comandos executados separadamente.
-- =====================================================================
begin;

-- apagar_codigo() exatamente como na migração 001
create or replace function public.apagar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;
  delete from public.codigos
  where id = p_id and autor_id = (auth.jwt() ->> 'sub')
    and not exists (select 1 from public.copias where codigo_id = p_id);
  return found;
end $$;

grant execute on function public.apagar_codigo(bigint) to authenticated;
revoke all on function public.apagar_codigo(bigint) from public, anon;

update public.migracoes set revertida_em = now() where versao = '005_apagar_codigo_trava';

commit;
