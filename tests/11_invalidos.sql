-- Testes da migração 004: relatos de inválidos, suspensão, confirmação,
-- reversão e bloqueio de republicação. Rodar DEPOIS da 004.
-- Usa só a plataforma 77 (limpa no início) e usuários "f4_".
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

insert into public.usuarios (id, nome, papel, situacao) values
  ('f4_a', 'f4a', 'membro', 'ativo'), ('f4_b', 'f4b', 'membro', 'ativo'), ('f4_c', 'f4c', 'membro', 'ativo'),
  ('f4_d', 'f4d', 'membro', 'ativo'), ('f4_adm', 'f4adm', 'admin', 'ativo'),
  ('f4_pend', 'f4pend', 'pendente', 'ativo'), ('f4_susp', 'f4susp', 'membro', 'suspenso');
delete from public.codigos where plataforma = '77';

create function teste.f4_id(p text) returns bigint language sql as $$
  select max(id) from public.codigos where plataforma = '77' and codigo = p $$;
create temp table r (k text primary key, v json);
grant select, insert, update on r to authenticated;

-- ---------- 1. publicação e cópias de base ----------
select teste.como('f4_a', 'f4a'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['F4A1','F4A2','F4A3','F4A4','F4A5','F4A6']) ->> 'adicionados')::int = 6, 'f4a publica 6 códigos');
select teste.ok((public.postar_codigos('77', array['F4A1']) -> 'bloqueados')::jsonb = '[]', 'postar devolve a lista bloqueados (vazia)');
select teste.como('f4_b', 'f4b');
select from (select public.copiar_codigo_v2(teste.f4_id('F4A1')), public.copiar_codigo_v2(teste.f4_id('F4A2'))) _;
select teste.como('f4_c', 'f4c');
select from (select public.copiar_codigo_v2(teste.f4_id('F4A1'))) _;
reset role;
create temp table antes_hist as
  select (select count(*) from public.copias) copias,
         (select count(*) from public.codigos where autor_id = 'f4_a') postados;
grant select on antes_hist to authenticated;

-- ---------- 2. entrada e categorias ----------
select teste.como('f4_b', 'f4b'); set role authenticated;
insert into r values ('b1', public.relatar_invalidos('77', array['F4A1', ' F4A1 ', 'F4A2', 'F4A3', '', 'NAOEXISTE', 'bad code!', 'F4A1']));
select teste.ok((v->>'recebidos')::int = 5 and (v->>'formato_invalido')::int = 1 and (v->>'encontrados')::int = 3
            and (v->>'nao_encontrados')::int = 1 and (v->>'reportados')::int = 3 and (v->>'suspensos_agora')::int = 0,
            'entrada: duplicatas e espaços removidos; 5 únicos = 3 encontrados + 1 não encontrado + 1 formato inválido') from r where k = 'b1';
select teste.ok((public.relatar_invalidos('77', array['F4A1','F4A2','F4A3']) ->> 'ja_reportados')::int = 3, 'mesmo usuário, mesmos códigos: ja_reportados (uma vez por pessoa)');
select teste.ok((public.relatar_invalidos('777', array['F4A1']) ->> 'nao_encontrados')::int = 1, 'código de outra plataforma: não encontrado');
select teste.erro($$select public.relatar_invalidos('XYZ', array['F4A1'])$$, 'plataforma_invalida', 'plataforma inexistente recusada');
select teste.erro($$select public.relatar_invalidos('77', array[' ', ''])$$, 'lista_vazia', 'lista vazia recusada');
select teste.erro($$select public.relatar_invalidos('77', (select array_agg('X' || g) from generate_series(1, 501) g))$$, 'maximo_500_por_vez', '501 códigos recusados');
select teste.como('f4_a', 'f4a');
select teste.ok((public.relatar_invalidos('77', array['F4A1','F4A2']) ->> 'proprios')::int = 2, 'autor não relata o próprio código');
reset role;
select teste.ok((select count(*) from public.relatos_invalidos where usuario_id = 'f4_a') = 0, 'relato do autor não foi gravado');
select teste.ok((select string_agg(codigo || '=' || qualificado, ',' order by codigo) from public.relatos_invalidos where usuario_id = 'f4_b')
                = 'F4A1=true,F4A2=true,F4A3=false', 'qualificado = copiou aquela publicação pelo mural');

-- ---------- 3. suspensão automática: 2 relatos QUALIFICADOS ----------
select teste.como('f4_c', 'f4c'); set role authenticated;
select teste.ok((public.relatar_invalidos('77', array['F4A1', 'F4A3']) ->> 'suspensos_agora')::int = 1, 'f4c (copiou F4A1) relata: F4A1 suspenso; F4A3 não (ninguém copiou)');
select teste.como('f4_d', 'f4d');
select teste.ok((public.relatar_invalidos('77', array['F4A3']) ->> 'suspensos_agora')::int = 0, '3 relatos NÃO qualificados não suspendem');
reset role;
select teste.ok((select desativacao from public.codigos where id = teste.f4_id('F4A1')) = 'relatos', 'F4A1 desativado (lógico) por relatos');
select teste.ok((select count(*) from public.eventos_invalidos where codigo = 'F4A1' and acao = 'suspenso_automatico') = 1, 'evento de suspensão automática registrado');

-- todos os caminhos recusam o desativado
select teste.como('f4_d', 'f4d'); set role authenticated;
select teste.ok(not exists (select 1 from public.codigos_ativos where codigo = 'F4A1'), 'codigos_ativos: desativado não aparece');
select teste.ok((public.copiar_codigo_v2(teste.f4_id('F4A1')) ->> 'status') = 'invalidado', 'copiar_codigo_v2: status invalidado');
select teste.ok(public.copiar_codigo(teste.f4_id('F4A1')) = false, 'copiar_codigo (v1): recusa');
insert into r values ('lote_d', public.pegar_lote('77', 10));
select teste.ok(not exists (select 1 from json_array_elements(v -> 'codigos') x where x ->> 'codigo' = 'F4A1')
                and (v ->> 'registrados')::int = 5, 'pegar_lote: leva os 5 ativos, nunca o desativado') from r where k = 'lote_d';
reset role;
select teste.ok((select count(*) from public.copias where codigo_id = teste.f4_id('F4A1')) = 2, 'nenhuma cópia nova no desativado; as 2 antigas intactas');

-- ---------- 4. histórico e ranking ----------
select teste.como('f4_adm', 'f4adm'); set role authenticated;
select teste.ok((public.admin_confirmar_invalido('77', 'F4A4', 'teste') ->> 'desativados_agora')::int = 1, 'admin confirma F4A4 (estava no lote de f4d)');
select teste.como('f4_d', 'f4d');
select teste.ok(exists (select 1 from json_array_elements(public.recuperar_lote((select (v->>'lote_id')::uuid from r where k = 'lote_d')) -> 'codigos') x
                        where x ->> 'codigo' = 'F4A4'), 'recuperar_lote: lote antigo continua com o código desativado depois (histórico íntegro)');
select teste.ok((select postados from public.ranking where id = 'f4_a') = (select postados from antes_hist), 'ranking: postados históricos inalterados');
select teste.ok((select ativos from public.ranking where id = 'f4_a') = 4, 'ranking: ativos exclui os 2 desativados (6 - 2)');
select teste.ok((select aproveitados from public.ranking where id = 'f4_a') = 6, 'ranking: aproveitados históricos inalterados');
reset role;
select teste.ok((select count(*) from public.copias) >= (select copias from antes_hist), 'nenhuma cópia apagada');

-- ---------- 5. republicação ----------
select teste.como('f4_b', 'f4b'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['F4A1']) ->> 'repetidos') = '["F4A1"]', 'suspenso por relatos, dentro de 48 h: republicação recusada (repetido)');
reset role;
update public.codigos set criado_em = now() - interval '49 hours' where plataforma = '77' and codigo in ('F4A1', 'F4A4');
select teste.como('f4_b', 'f4b'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['F4A1']) ->> 'adicionados')::int = 1, 'suspenso só por relatos: após 48 h pode ser republicado (não confirmado)');
select teste.ok(exists (select 1 from public.codigos_ativos where codigo = 'F4A1'), 'a nova publicação de F4A1 fica ativa');
select teste.ok((public.postar_codigos('77', array['F4A4']) -> 'bloqueados')::jsonb = '["F4A4"]'
                and (select count(*) from public.codigos where codigo = 'F4A4') = 1, 'confirmado pelo admin: bloqueado mesmo após 48 h; nada inserido');
select teste.como('f4_c', 'f4c');
select teste.ok((public.relatar_invalidos('77', array['F4A1']) ->> 'reportados')::int = 1, 'relato vai para a publicação MAIS RECENTE (nova linha de F4A1)');
select teste.ok((public.relatar_invalidos('77', array['F4A4']) ->> 'ja_desativados')::int = 1, 'relatar código bloqueado: já desativado');
reset role;
select teste.ok((select count(*) from public.relatos_invalidos where codigo = 'F4A1' and codigo_id = teste.f4_id('F4A1')) = 1, 'relato novo ligado à linha nova');

-- ---------- 6. administração ----------
select teste.como('f4_b', 'f4b'); set role authenticated;
select teste.erro($$select public.admin_codigos_invalidos()$$, 'acesso_negado', 'membro não lista relatos');
select teste.erro($$select public.admin_confirmar_invalido('77', 'F4A3')$$, 'acesso_negado', 'membro não confirma');
select teste.erro($$select public.admin_reverter_invalido('77', 'F4A4')$$, 'acesso_negado', 'membro não reverte');
select teste.como('f4_adm', 'f4adm');
insert into r values ('adm', public.admin_codigos_invalidos());
select teste.ok((select count(*) from json_array_elements(v -> 'publicacoes') x where x ->> 'codigo' = 'F4A3' and (x ->> 'relatos')::int = 3 and (x ->> 'qualificados')::int = 0) = 1
            and (select count(*) from json_array_elements(v -> 'bloqueados') x where x ->> 'codigo' = 'F4A4') = 1,
            'admin vê relatos (3, 0 qualificados) e bloqueios') from r where k = 'adm';
select teste.erro($$select public.admin_confirmar_invalido('77', 'bad code!')$$, 'codigo_invalido', 'admin: código com formato inválido recusado');
-- reverter confirmação
insert into r values ('rev', public.admin_reverter_invalido('77', 'F4A4', 'engano'));
select teste.ok((v ->> 'status') = 'revertido' and (v ->> 'desbloqueado')::boolean, 'admin reverte F4A4: desbloqueado') from r where k = 'rev';
select teste.ok((public.admin_reverter_invalido('77', 'F4A4') ->> 'status') = 'nada_a_reverter', 'reverter de novo: nada a reverter');
select teste.como('f4_b', 'f4b');
select teste.ok((public.postar_codigos('77', array['F4A4']) ->> 'adicionados')::int = 1, 'depois de revertido, pode republicar');
-- reverter suspensão automática: reativa e os relatos antigos não suspendem de novo
select teste.como('f4_adm', 'f4adm');
update r set v = public.admin_reverter_invalido('77', 'F4A1') where k = 'rev';
reset role;
select teste.ok((select count(*) from public.codigos where codigo = 'F4A1' and desativado_em is not null) = 0
                and (select count(*) from public.relatos_invalidos where codigo = 'F4A1' and descartado_em is null) = 0,
                'reverter F4A1: publicações reativadas e relatos descartados');
select teste.como('f4_c', 'f4c'); set role authenticated;
select teste.ok((public.relatar_invalidos('77', array['F4A1']) ->> 'ja_reportados')::int = 1, 'mesma pessoa não relata de novo a mesma publicação');
-- descartar relatos sem desativação (F4A3)
select teste.como('f4_adm', 'f4adm');
select teste.ok((public.admin_reverter_invalido('77', 'F4A3') ->> 'relatos_descartados')::int = 3, 'admin descarta relatos de F4A3');
-- confirmar código que não existe no mural impede publicação futura
select teste.ok((public.admin_confirmar_invalido('77', 'F4FANTASMA') ->> 'desativados_agora')::int = 0, 'admin bloqueia código ainda não publicado');
select teste.como('f4_b', 'f4b');
select teste.ok((public.postar_codigos('77', array['F4FANTASMA']) -> 'bloqueados')::jsonb = '["F4FANTASMA"]', 'código bloqueado não entra');
reset role;
select teste.ok((select string_agg(acao, ',' order by id) from public.eventos_invalidos where plataforma = '77')
                = 'suspenso_automatico,confirmado,revertido,revertido,revertido,confirmado', 'auditoria completa em eventos_invalidos');

-- ---------- 7. confirmação absorve suspensão; autor apaga relatado ----------
select teste.como('f4_c', 'f4c'); set role authenticated;
select from (select public.copiar_codigo_v2(teste.f4_id('F4A5'))) _;
select teste.como('f4_b', 'f4b');
select from (select public.copiar_codigo_v2(teste.f4_id('F4A5')), public.relatar_invalidos('77', array['F4A5'])) _;
select teste.como('f4_c', 'f4c');
select from (select public.relatar_invalidos('77', array['F4A5'])) _;
select teste.como('f4_adm', 'f4adm');
select from (select public.admin_confirmar_invalido('77', 'F4A5')) _;
reset role;
select teste.ok((select desativacao from public.codigos where id = teste.f4_id('F4A5')) = 'admin', 'suspensa por relatos e depois confirmada: passa a constar como admin');
select teste.como('f4_a', 'f4a'); set role authenticated;
select from (select public.postar_codigos('77', array['F4APAGAR'])) _;
select teste.como('f4_d', 'f4d');
select from (select public.relatar_invalidos('77', array['F4APAGAR'])) _;
select teste.como('f4_a', 'f4a');
select teste.ok(public.apagar_codigo(teste.f4_id('F4APAGAR')), 'autor ainda pode apagar o próprio código relatado sem cópias');
reset role;
select teste.ok((select codigo_id is null from public.relatos_invalidos where codigo = 'F4APAGAR'), 'relato preservado (codigo_id vira nulo)');

-- ---------- 8. permissões ----------
select teste.como('f4_pend', 'f4pend'); set role authenticated;
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'acesso_negado', 'pendente não relata');
select teste.como('f4_susp', 'f4susp');
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'acesso_negado', 'suspenso não relata');
select teste.como('f4_b', 'f4b');
select teste.erro($$select * from public.relatos_invalidos$$, 'permission denied', 'membro não lê relatos direto');
select teste.erro($$insert into public.relatos_invalidos (plataforma, codigo, usuario_id, qualificado) values ('77','X','f4_b',true)$$, 'permission denied', 'membro não insere relato direto');
select teste.erro($$delete from public.codigos_bloqueados$$, 'permission denied', 'membro não mexe em bloqueios');
select teste.erro($$update public.codigos set desativado_em = null$$, 'permission denied', 'membro não reativa código direto');
select teste.erro($$select * from public.eventos_invalidos$$, 'permission denied', 'membro não lê eventos');
reset role;
set role anon;
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'permission denied', 'anônimo não relata');
reset role;

delete from public.codigos where plataforma = '77';
select 'TODOS OS TESTES DE CÓDIGOS INVÁLIDOS PASSARAM';
