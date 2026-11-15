-- =====================================================================
-- Migração 005 — apagar_codigo() sem condição de corrida com as cópias
--
-- Pré-requisito: migração 001 aplicada (e não revertida). Independente da
-- 002/003/004: pode ser aplicada antes ou depois delas.
--
-- O PROBLEMA (versão da 001):
--   delete from codigos where id = p_id and autor_id = <eu>
--     and not exists (select 1 from copias where codigo_id = p_id);
--   Num único comando, o NOT EXISTS usa a foto (snapshot) tirada no INÍCIO
--   do comando. Se uma cópia estiver em andamento (a função de cópia/lote
--   segura a linha do código com FOR UPDATE e já inseriu em copias, mas
--   ainda não confirmou), o DELETE espera a trava; quando a cópia confirma,
--   o DELETE segue com a foto antiga (que não tem a cópia), apaga o código e
--   o ON DELETE CASCADE de copias apaga junto a cópia recém-confirmada.
--
-- A CORREÇÃO: separar em comandos. Em READ COMMITTED (padrão do Supabase),
-- cada comando de uma função plpgsql tira foto nova. Então:
--   1. confere o autor (leitura simples; autor_id nunca muda) — quem não é
--      o autor nem chega a travar a linha de outra pessoa;
--   2. trava a linha com SELECT ... FOR UPDATE — a MESMA trava das funções de
--      cópia e do lote; espera uma cópia em andamento terminar;
--   3. com a trava, confere as cópias num comando NOVO (foto nova, enxerga a
--      cópia que acabou de ser confirmada) — e, enquanto a trava for nossa,
--      ninguém consegue registrar cópia (FOR UPDATE das cópias e o FOR KEY
--      SHARE da chave estrangeira de copias esperam por nós);
--   4. só então apaga.
-- Mesma assinatura, mesmo retorno booleano, mesmas permissões e regras
-- (membro ativo; só o autor; só sem cópias).
--
-- Seguro no SQL Editor com comandos separados; idempotente; primeira
-- aplicação x reaplicação lida de public.migracoes.
-- Como aplicar e reverter: docs/IMPLANTACAO.md, seção "Migração 005".
-- =====================================================================
begin;

do $$
begin
  if to_regclass('public.migracoes') is null
     or not exists (select 1 from public.migracoes where versao = '001_membros' and revertida_em is null) then
    raise exception 'A migração 001_membros precisa estar aplicada antes da 005.';
  end if;
end $$;

create or replace function public.apagar_codigo(p_id bigint)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_id text := auth.jwt() ->> 'sub';
begin
  if not public.eh_membro() then raise exception 'acesso_negado'; end if;

  -- 1. só o autor (sem travar código dos outros)
  if not exists (select 1 from public.codigos where id = p_id and autor_id = v_id) then
    return false;
  end if;

  -- 2. mesma trava de linha das cópias e do lote; espera cópia em andamento
  perform 1 from public.codigos where id = p_id and autor_id = v_id for update;
  if not found then return false; end if;               -- apagado no meio por outra chamada

  -- 3. comando novo = foto nova: enxerga cópias confirmadas antes da trava
  if exists (select 1 from public.copias where codigo_id = p_id) then
    return false;
  end if;

  -- 4. com a trava, nenhuma cópia pode surgir até o fim desta transação
  delete from public.codigos where id = p_id;
  return found;
end $$;

-- create or replace mantém os privilégios; reafirma sem tirar o acesso de
-- authenticated nem por um instante
grant execute on function public.apagar_codigo(bigint) to authenticated;
revoke all on function public.apagar_codigo(bigint) from public, anon;

insert into public.migracoes (versao) values ('005_apagar_codigo_trava')
on conflict (versao) do update
  set ultima_aplicacao = now(), aplicacoes = public.migracoes.aplicacoes + 1, revertida_em = null;

do $$
declare
  v_aplicacoes int := (select aplicacoes from public.migracoes where versao = '005_apagar_codigo_trava');
begin
  if v_aplicacoes = 1 then
    raise notice 'MIGRAÇÃO 005 APLICADA: apagar_codigo() trava o código antes de conferir as cópias; nenhum dado alterado.';
  else
    raise notice 'MIGRAÇÃO 005 REAPLICADA (execução nº %): apagar_codigo() atualizada; nenhum dado alterado.', v_aplicacoes;
  end if;
end $$;

commit;
