-- Testes da migração 004: relatos de inválidos, associação à publicação
-- copiada, suspensão, confirmação, desbloqueio, reativação e auditoria.
-- Rodar DEPOIS da 004. Usa só a plataforma 77 (limpa no início) e usuários "f4_".
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

insert into public.usuarios (id, nome, papel, situacao) values
  ('f4_a', 'f4a', 'membro', 'ativo'), ('f4_b', 'f4b', 'membro', 'ativo'), ('f4_c', 'f4c', 'membro', 'ativo'),
  ('f4_d', 'f4d', 'membro', 'ativo'), ('f4_e', 'f4e', 'membro', 'ativo'), ('f4_adm', 'f4adm', 'admin', 'ativo'),
  ('f4_pend', 'f4pend', 'pendente', 'ativo'), ('f4_susp', 'f4susp', 'membro', 'suspenso');
delete from public.codigos where plataforma = '77';

-- publicação mais recente / publicação n (1 = mais antiga) de um código
create function teste.f4_id(p text) returns bigint language sql as $$
  select max(id) from public.codigos where plataforma = '77' and codigo = p $$;
create function teste.f4_pub(p text, n int) returns bigint language sql as $$
  select id from public.codigos where plataforma = '77' and codigo = p order by id offset n - 1 limit 1 $$;
-- publica direto (com idade) e registra cópias (com idade) — só para montar cenários
create function teste.f4_publica(p text, autor text, horas int default 1) returns bigint language sql as $$
  insert into public.codigos (plataforma, codigo, autor_id, criado_em) values ('77', p, autor, now() - horas * interval '1 hour') returning id $$;
create function teste.f4_copia(id bigint, u text, horas int default 0) returns void language sql as $$
  insert into public.copias (codigo_id, usuario_id, criado_em) values (id, u, now() - horas * interval '1 hour') $$;
create function teste.f4_estado(id bigint) returns text language sql as $$
  select coalesce(desativacao, 'ativo') from public.codigos where codigos.id = f4_estado.id $$;
create temp table r (k text primary key, v json);
grant select, insert, update on r to authenticated;

-- =====================================================================
-- 1. Entrada e categorias
-- =====================================================================
select teste.como('f4_a', 'f4a'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['F4A1','F4A2','F4A3','F4A4','F4A5','F4A6']) ->> 'adicionados')::int = 6, 'f4a publica 6 códigos');
select teste.ok((public.postar_codigos('77', array['F4A1']) -> 'bloqueados')::jsonb = '[]', 'postar devolve a lista bloqueados (vazia)');
select teste.como('f4_b', 'f4b');
select from (select public.copiar_codigo_v2(teste.f4_id('F4A1')), public.copiar_codigo_v2(teste.f4_id('F4A2'))) _;
select teste.como('f4_c', 'f4c');
select from (select public.copiar_codigo_v2(teste.f4_id('F4A1'))) _;
reset role;
create temp table antes_hist as
  select (select count(*) from public.copias) copias, (select count(*) from public.codigos where autor_id = 'f4_a') postados;
grant select on antes_hist to authenticated;

select teste.como('f4_b', 'f4b'); set role authenticated;
insert into r values ('b1', public.relatar_invalidos('77', array['F4A1', ' F4A1 ', 'F4A2', 'F4A3', '', 'NAOEXISTE', 'bad code!', 'F4A1']));
select teste.ok((v->>'recebidos')::int = 5 and (v->>'formato_invalido')::int = 1 and (v->>'encontrados')::int = 3
            and (v->>'nao_encontrados')::int = 1 and (v->>'reportados')::int = 3 and (v->>'nao_contam')::int = 1
            and (v->>'suspensos_agora')::int = 0,
            'entrada: 5 únicos = 3 encontrados + 1 não encontrado + 1 formato inválido; F4A3 (não copiado) não conta') from r where k = 'b1';
select teste.ok((public.relatar_invalidos('77', array['F4A1','F4A2','F4A3']) ->> 'ja_reportados')::int = 3, 'mesma pessoa, mesmas publicações: ja_reportados');
select teste.ok((public.relatar_invalidos('777', array['F4A1']) ->> 'nao_encontrados')::int = 1, 'código de outra plataforma: não encontrado');
select teste.erro($$select public.relatar_invalidos('XYZ', array['F4A1'])$$, 'plataforma_invalida', 'plataforma inexistente recusada');
select teste.erro($$select public.relatar_invalidos('77', array[' ', ''])$$, 'lista_vazia', 'lista vazia recusada');
select teste.erro($$select public.relatar_invalidos('77', (select array_agg('X' || g) from generate_series(1, 501) g))$$, 'maximo_500_por_vez', '501 códigos recusados');
select teste.como('f4_a', 'f4a');
select teste.ok((public.relatar_invalidos('77', array['F4A1','F4A2']) ->> 'proprios')::int = 2, 'autor não relata o próprio código');
reset role;
select teste.ok((select count(*) from public.relatos_invalidos where usuario_id = 'f4_a') = 0, 'relato do autor não foi gravado');
select teste.ok((select string_agg(codigo || '=' || associacao || '/' || qualificado, ',' order by codigo) from public.relatos_invalidos where usuario_id = 'f4_b')
                = 'F4A1=copiada/true,F4A2=copiada/true,F4A3=sem_copia/false', 'associação: copiada (qualificado) x sem_copia (não conta)');
select teste.ok((select bool_and(copia_em is not null) from public.relatos_invalidos where associacao = 'copiada'), 'relato copiado guarda quando a pessoa copiou');

-- =====================================================================
-- 2. Suspensão automática e todos os caminhos de cópia/distribuição
-- =====================================================================
select teste.como('f4_c', 'f4c'); set role authenticated;
select teste.ok((public.relatar_invalidos('77', array['F4A1', 'F4A3']) ->> 'suspensos_agora')::int = 1, 'f4c (copiou F4A1) relata: F4A1 suspenso; F4A3 não (ninguém copiou)');
select teste.como('f4_d', 'f4d');
select teste.ok((public.relatar_invalidos('77', array['F4A3']) ->> 'suspensos_agora')::int = 0, '3 relatos sem cópia não suspendem');
reset role;
select teste.ok(teste.f4_estado(teste.f4_id('F4A1')) = 'relatos', 'F4A1 suspenso (lógico) por relatos');
select teste.ok((select estado_anterior from public.eventos_invalidos where codigo = 'F4A1' and acao = 'suspenso_automatico') = 'ativo', 'evento de suspensão com estado anterior');

select teste.como('f4_d', 'f4d'); set role authenticated;
select teste.ok(not exists (select 1 from public.codigos_ativos where codigo = 'F4A1'), 'codigos_ativos: desativado não aparece');
select teste.ok((public.copiar_codigo_v2(teste.f4_id('F4A1')) ->> 'status') = 'invalidado', 'copiar_codigo_v2: status invalidado');
select teste.ok(public.copiar_codigo(teste.f4_id('F4A1')) = false, 'copiar_codigo (v1): recusa');
insert into r values ('lote_d', public.pegar_lote('77', 10));
select teste.ok(not exists (select 1 from json_array_elements(v -> 'codigos') x where x ->> 'codigo' = 'F4A1')
                and (v ->> 'registrados')::int = 5, 'pegar_lote: leva os 5 ativos, nunca o desativado') from r where k = 'lote_d';
reset role;
select teste.ok((select count(*) from public.copias where codigo_id = teste.f4_id('F4A1')) = 2, 'nenhuma cópia nova no desativado; as 2 antigas intactas');
-- regressão: TODA função que grava em copias também filtra desativados
select teste.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                             where n.nspname = 'public' and p.prosrc ilike '%insert into public.copias%'
                               and p.prosrc not ilike '%desativado_em%'),
                'catálogo: toda função que insere em copias confere desativado_em');
select teste.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.prosrc ilike '%insert into public.copias%') = 3,
                'catálogo: são exatamente 3 (copiar_codigo, copiar_codigo_v2, pegar_lote)');
select teste.ok(pg_get_viewdef('public.codigos_ativos') like '%desativado_em IS NULL%', 'catálogo: a view filtra desativados');

-- =====================================================================
-- 3. Histórico e ranking
-- =====================================================================
select teste.como('f4_adm', 'f4adm'); set role authenticated;
select teste.ok((public.admin_confirmar_invalido(teste.f4_id('F4A4'), 'teste') ->> 'status') = 'confirmado', 'admin confirma F4A4 (estava no lote de f4d)');
select teste.como('f4_d', 'f4d');
select teste.ok(exists (select 1 from json_array_elements(public.recuperar_lote((select (v->>'lote_id')::uuid from r where k = 'lote_d')) -> 'codigos') x
                        where x ->> 'codigo' = 'F4A4'), 'recuperar_lote: lote antigo continua com o código desativado depois (histórico íntegro)');
select teste.ok((select postados from public.ranking where id = 'f4_a') = (select postados from antes_hist), 'ranking: postados históricos inalterados');
select teste.ok((select ativos from public.ranking where id = 'f4_a') = 4, 'ranking: ativos exclui os 2 desativados (6 - 2)');
select teste.ok((select aproveitados from public.ranking where id = 'f4_a') = 6, 'ranking: aproveitados históricos inalterados');
reset role;
select teste.ok((select count(*) from public.copias) >= (select copias from antes_hist), 'nenhuma cópia apagada');

-- =====================================================================
-- 4. ASSOCIAÇÃO: relato vai para a publicação que a pessoa copiou
-- =====================================================================
-- H1: publicação antiga (copiada por b) e republicação nova (b não copiou).
-- b cola o histórico do comprador: o relato vai para a ANTIGA, não para a nova.
select from (select teste.f4_publica('H1', 'f4_a', 50)) _;                 -- publicação 1 (vencida)
select from (select teste.f4_copia(teste.f4_pub('H1', 1), 'f4_b', 49)) _;
select from (select teste.f4_publica('H1', 'f4_e', 1)) _;                  -- republicação nova
select teste.como('f4_b', 'f4b'); set role authenticated;
select from (select public.relatar_invalidos('77', array['H1'])) _;
reset role;
select teste.ok((select codigo_id from public.relatos_invalidos where usuario_id = 'f4_b' and codigo = 'H1') = teste.f4_pub('H1', 1),
                'histórico colado: relato vai para a publicação que a pessoa copiou (a antiga), não para a republicação');
select teste.ok((select associacao from public.relatos_invalidos where usuario_id = 'f4_b' and codigo = 'H1') = 'copiada', 'e conta (copiou há 49 h, dentro de 72 h)');
select teste.ok(not exists (select 1 from public.relatos_invalidos where codigo_id = teste.f4_pub('H1', 2)), 'a republicação nova não recebeu nada');

-- H2: pessoa que copiou as DUAS publicações -> ambígua, não conta
select from (select teste.f4_publica('H2', 'f4_a', 60)) _;
select from (select teste.f4_copia(teste.f4_pub('H2', 1), 'f4_c', 59), teste.f4_copia(teste.f4_pub('H2', 1), 'f4_b', 59)) _;
select from (select teste.f4_publica('H2', 'f4_a', 2)) _;
select from (select teste.f4_copia(teste.f4_pub('H2', 2), 'f4_c', 1), teste.f4_copia(teste.f4_pub('H2', 2), 'f4_b', 1)) _;
select teste.como('f4_c', 'f4c'); set role authenticated;
insert into r values ('h2c', public.relatar_invalidos('77', array['H2']));
select teste.como('f4_b', 'f4b');
insert into r values ('h2b', public.relatar_invalidos('77', array['H2']));
reset role;
select teste.ok((select string_agg(associacao, ',') from public.relatos_invalidos where codigo = 'H2') = 'ambigua,ambigua'
                and (select bool_and(codigo_id = teste.f4_pub('H2', 2)) from public.relatos_invalidos where codigo = 'H2'),
                'copiou duas publicações do mesmo código: ambígua, ligada à mais recente copiada');
select teste.ok(teste.f4_estado(teste.f4_pub('H2', 2)) = 'ativo' and (select (v ->> 'nao_contam')::int from r where k = 'h2b') = 1,
                '2 relatos ambíguos NÃO suspendem');

-- H3: cópia com mais de 72 h -> fora do prazo, não conta
select from (select teste.f4_publica('H3', 'f4_a', 47)) _;
select from (select teste.f4_copia(teste.f4_pub('H3', 1), 'f4_b', 46), teste.f4_copia(teste.f4_pub('H3', 1), 'f4_c', 46)) _;
update public.codigos set criado_em = now() - interval '100 hours' where id = teste.f4_pub('H3', 1);
update public.copias set criado_em = now() - interval '90 hours' where codigo_id = teste.f4_pub('H3', 1);
select teste.como('f4_b', 'f4b'); set role authenticated;
select from (select public.relatar_invalidos('77', array['H3'])) _;
select teste.como('f4_c', 'f4c');
select from (select public.relatar_invalidos('77', array['H3'])) _;
reset role;
select teste.ok((select string_agg(associacao, ',') from public.relatos_invalidos where codigo = 'H3') = 'fora_do_prazo,fora_do_prazo'
                and teste.f4_estado(teste.f4_pub('H3', 1)) = 'ativo', 'cópias de 90 h atrás: fora do prazo, não suspendem');

-- =====================================================================
-- 5. Relatos antigos x republicação nova; publicação vencida
-- =====================================================================
-- R1 suspenso por b e c; republicado depois; d copia a nova e relata.
select from (select teste.f4_publica('R1', 'f4_a', 40)) _;
select from (select teste.f4_copia(teste.f4_pub('R1', 1), 'f4_b', 39), teste.f4_copia(teste.f4_pub('R1', 1), 'f4_c', 39)) _;
select teste.como('f4_b', 'f4b'); set role authenticated;
select from (select public.relatar_invalidos('77', array['R1'])) _;
select teste.como('f4_c', 'f4c');
select from (select public.relatar_invalidos('77', array['R1'])) _;
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('R1', 1)) = 'relatos', 'R1 (publicação 1) suspenso por b e c');
update public.codigos set criado_em = now() - interval '49 hours' where id = teste.f4_pub('R1', 1);
select teste.como('f4_e', 'f4e'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['R1']) ->> 'adicionados')::int = 1, 'suspenso só por relatos: republicação permitida após 48 h');
select teste.como('f4_d', 'f4d');
select teste.ok((public.copiar_codigo_v2(teste.f4_pub('R1', 2)) ->> 'status') = 'registrado', 'd copia a republicação');
select teste.ok((public.relatar_invalidos('77', array['R1']) ->> 'suspensos_agora')::int = 0, 'um relato novo na republicação: não suspende');
select teste.como('f4_b', 'f4b');
select teste.ok((public.relatar_invalidos('77', array['R1']) ->> 'ja_desativados')::int = 1, 'b cola o histórico de novo: vai para a publicação que ele copiou (já suspensa), não para a nova');
select teste.como('f4_c', 'f4c');
select from (select public.relatar_invalidos('77', array['R1'])) _;
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('R1', 2)) = 'ativo'
                and (select count(*) from public.relatos_invalidos where codigo_id = teste.f4_pub('R1', 2)) = 1,
                'relatos antigos NUNCA suspendem a republicação (ela começa do zero)');

-- V1: publicação vencida recebe relatos qualificados (cópia dentro de 72 h):
-- é suspensa (só registro; já estava fora da distribuição) e NÃO bloqueia republicação
select from (select teste.f4_publica('V1', 'f4_a', 60)) _;
select from (select teste.f4_copia(teste.f4_pub('V1', 1), 'f4_b', 55), teste.f4_copia(teste.f4_pub('V1', 1), 'f4_c', 55)) _;
select teste.como('f4_b', 'f4b'); set role authenticated;
select from (select public.relatar_invalidos('77', array['V1'])) _;
select teste.como('f4_c', 'f4c');
select teste.ok((public.relatar_invalidos('77', array['V1']) ->> 'suspensos_agora')::int = 1, 'publicação vencida, cópias de 55 h: relatos qualificados registram a suspensão');
select teste.como('f4_e', 'f4e');
select teste.ok((public.postar_codigos('77', array['V1']) ->> 'adicionados')::int = 1, 'suspensão automática de vencida não bloqueia republicar');
reset role;

-- =====================================================================
-- 6. Restrição da conta: 2 contas rejeitadas suspendem SÓ aquela
--    publicação; admin reativa e os mesmos relatos não suspendem de novo
-- =====================================================================
select from (select teste.f4_publica('K1', 'f4_a', 3)) _;
select from (select teste.f4_copia(teste.f4_pub('K1', 1), 'f4_b', 2), teste.f4_copia(teste.f4_pub('K1', 1), 'f4_c', 2)) _;
select teste.como('f4_b', 'f4b'); set role authenticated;
select from (select public.relatar_invalidos('77', array['K1'])) _;
select teste.como('f4_c', 'f4c');
select from (select public.relatar_invalidos('77', array['K1'])) _;
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('K1', 1)) = 'relatos' and not exists (select 1 from public.codigos_bloqueados where codigo = 'K1'),
                'restrição de conta (b e c): só a publicação é suspensa, sem bloqueio');
select teste.como('f4_adm', 'f4adm'); set role authenticated;
insert into r values ('k1', public.admin_reativar_publicacao(teste.f4_pub('K1', 1), 'conta antiga, cupom só para novos'));
select teste.ok((v ->> 'status') = 'reativado' and (v ->> 'estado_anterior') = 'relatos' and (v ->> 'relatos_descartados')::int = 2,
                'admin reativa K1: estado anterior relatos, 2 relatos descartados') from r where k = 'k1';
select teste.como('f4_c', 'f4c');
select teste.ok((public.relatar_invalidos('77', array['K1']) ->> 'ja_reportados')::int = 1, 'quem já relatou não relata de novo a mesma publicação');
select teste.como('f4_d', 'f4d');
select from (select public.copiar_codigo_v2(teste.f4_pub('K1', 1)), public.relatar_invalidos('77', array['K1'])) _;
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('K1', 1)) = 'ativo', 'um terceiro relato qualificado sozinho não suspende de novo');
select teste.ok((select count(*) from public.relatos_invalidos where codigo = 'K1') = 3
                and (select count(*) from public.relatos_invalidos where codigo = 'K1' and descartado_por = 'f4_adm') = 2,
                'relatos descartados são mantidos (com quem descartou)');

-- =====================================================================
-- 7. Confirmação, desbloqueio e reativação separados + auditoria
-- =====================================================================
-- C1: 3 publicações do mesmo código: p1 suspensa por relatos (motivo
-- independente), p2 ativa, p3 a confirmada pelo admin
select from (select teste.f4_publica('C1', 'f4_a', 120), teste.f4_publica('C1', 'f4_a', 70), teste.f4_publica('C1', 'f4_e', 2)) _;
update public.codigos set desativado_em = now() - interval '100 hours', desativacao = 'relatos' where id = teste.f4_pub('C1', 1);
select teste.como('f4_b', 'f4b'); set role authenticated;
select teste.erro($$select public.admin_confirmar_invalido(1)$$, 'acesso_negado', 'membro não confirma');
select teste.erro($$select public.admin_desbloquear_codigo('77', 'C1')$$, 'acesso_negado', 'membro não desbloqueia');
select teste.erro($$select public.admin_reativar_publicacao(1)$$, 'acesso_negado', 'membro não reativa');
select teste.erro($$select public.admin_codigos_invalidos()$$, 'acesso_negado', 'membro não lista relatos');
select teste.como('f4_adm', 'f4adm');
select teste.erro($$select public.admin_confirmar_invalido(-1)$$, 'codigo_inexistente', 'confirmar publicação inexistente: erro claro');
insert into r values ('c1', public.admin_confirmar_invalido(teste.f4_pub('C1', 3), 'cupom expirado no site'));
select teste.ok((v ->> 'desativados_pelo_bloqueio')::int = 1, 'confirmar p3: p2 (ativa) desativada pelo bloqueio') from r where k = 'c1';
select teste.ok((public.admin_confirmar_invalido(teste.f4_pub('C1', 3)) ->> 'status') = 'ja_confirmado', 'confirmar de novo: já confirmado, nada muda');
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('C1', 1)) || ',' || teste.f4_estado(teste.f4_pub('C1', 2)) || ',' || teste.f4_estado(teste.f4_pub('C1', 3))
                = 'relatos,bloqueio,admin', 'motivos preservados: p1 relatos (independente), p2 bloqueio, p3 admin');
select teste.como('f4_e', 'f4e'); set role authenticated;
select teste.ok((public.postar_codigos('77', array['C1']) -> 'bloqueados')::jsonb = '["C1"]', 'combinação bloqueada: republicação recusada');
select teste.como('f4_adm', 'f4adm');
select teste.erro(format('select public.admin_reativar_publicacao(%s)', teste.f4_pub('C1', 3)), 'codigo_bloqueado', 'reativar publicação com a combinação bloqueada: recusado');
insert into r values ('d1', public.admin_desbloquear_codigo('77', 'C1', 'engano'));
select teste.ok((v ->> 'reativados')::int = 1 and (v ->> 'continuam_desativados')::int = 2,
                'desbloquear: reativa SÓ a desativada pelo bloqueio; as outras 2 continuam') from r where k = 'd1';
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('C1', 1)) || ',' || teste.f4_estado(teste.f4_pub('C1', 2)) || ',' || teste.f4_estado(teste.f4_pub('C1', 3))
                = 'relatos,ativo,admin', 'p1 (relatos) e p3 (confirmada) NÃO foram reativadas automaticamente');
select teste.como('f4_adm', 'f4adm'); set role authenticated;
select teste.ok((public.admin_desbloquear_codigo('77', 'C1') ->> 'status') = 'nao_bloqueado', 'desbloquear de novo: não estava bloqueado');
insert into r values ('rp3', public.admin_reativar_publicacao(teste.f4_pub('C1', 3), 'confirmado por engano'));
select teste.ok((v ->> 'estado_anterior') = 'admin', 'reativar p3 explicitamente: só ela') from r where k = 'rp3';
reset role;
select teste.ok(teste.f4_estado(teste.f4_pub('C1', 1)) = 'relatos', 'p1 continua suspensa (só o admin, explicitamente, a reativaria)');
select teste.ok((select string_agg(acao || ':' || coalesce(estado_anterior, '-') || ':' || coalesce(codigo_id = teste.f4_pub('C1', 3), false)::text
                                   || ':' || coalesce(codigo_id = teste.f4_pub('C1', 2), false)::text, ' ' order by id)
                   from public.eventos_invalidos where codigo = 'C1')
                = 'confirmado:ativo:true:false desativado_por_bloqueio:ativo:false:true desbloqueado:bloqueado:false:false '
                  || 'reativado_por_desbloqueio:bloqueio:false:true reativado:admin:true:false',
                'auditoria: cada mudança registrada, com publicação, estado anterior e na ordem');
select teste.ok((select bool_and(por_id = 'f4_adm') from public.eventos_invalidos where codigo = 'C1')
                and (select motivo from public.eventos_invalidos where codigo = 'C1' and acao = 'confirmado') = 'cupom expirado no site',
                'auditoria: quem fez e o motivo');
select teste.ok((select bool_and(por_id is null) from public.eventos_invalidos where acao = 'suspenso_automatico'), 'suspensão automática registrada sem autor (automática)');
-- confirmar uma publicação suspensa por relatos: estado anterior "relatos"
select teste.como('f4_adm', 'f4adm'); set role authenticated;
select from (select public.admin_confirmar_invalido(teste.f4_id('F4A1'))) _;
reset role;
select teste.ok((select estado_anterior from public.eventos_invalidos where codigo_id = teste.f4_id('F4A1') and acao = 'confirmado') = 'relatos',
                'confirmar suspensa por relatos: auditoria guarda o estado anterior');

-- admin vê tudo
select teste.como('f4_adm', 'f4adm'); set role authenticated;
insert into r values ('adm', public.admin_codigos_invalidos());
select teste.ok((select count(*) from json_array_elements(v -> 'publicacoes') x where x ->> 'codigo' = 'F4A3' and (x ->> 'relatos')::int = 3 and (x ->> 'qualificados')::int = 0) = 1
            and (select count(*) from json_array_elements(v -> 'bloqueados') x where x ->> 'codigo' = 'F4A4') = 1
            and json_array_length(v -> 'eventos') > 0, 'admin vê relatos (3, 0 qualificados), bloqueios e auditoria') from r where k = 'adm';
-- descartar relatos de publicação ativa
insert into r values ('desc', public.admin_reativar_publicacao(teste.f4_id('F4A3')));
select teste.ok((v ->> 'status') = 'relatos_descartados' and (v ->> 'relatos_descartados')::int = 3, 'admin descarta relatos de F4A3 (ativa)') from r where k = 'desc';
select teste.ok((public.admin_reativar_publicacao(teste.f4_id('F4A3')) ->> 'status') = 'nada_a_reverter', 'de novo: nada a reverter');
reset role;

-- =====================================================================
-- 8. Autor apaga relatado; permissões
-- =====================================================================
select teste.como('f4_a', 'f4a'); set role authenticated;
select from (select public.postar_codigos('77', array['F4APAGAR'])) _;
select teste.como('f4_d', 'f4d');
select from (select public.relatar_invalidos('77', array['F4APAGAR'])) _;
select teste.como('f4_a', 'f4a');
select teste.ok(public.apagar_codigo(teste.f4_id('F4APAGAR')), 'autor ainda pode apagar o próprio código relatado sem cópias');
reset role;
select teste.ok((select codigo_id is null from public.relatos_invalidos where codigo = 'F4APAGAR'), 'relato preservado (codigo_id vira nulo)');

select teste.como('f4_pend', 'f4pend'); set role authenticated;
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'acesso_negado', 'pendente não relata');
select teste.como('f4_susp', 'f4susp');
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'acesso_negado', 'suspenso não relata');
select teste.como('f4_b', 'f4b');
select teste.erro($$select * from public.relatos_invalidos$$, 'permission denied', 'membro não lê relatos direto');
select teste.erro($$insert into public.relatos_invalidos (plataforma, codigo, usuario_id, associacao, qualificado) values ('77','X','f4_b','copiada',true)$$, 'permission denied', 'membro não insere relato direto');
select teste.erro($$delete from public.codigos_bloqueados$$, 'permission denied', 'membro não mexe em bloqueios');
select teste.erro($$update public.codigos set desativado_em = null$$, 'permission denied', 'membro não reativa código direto');
select teste.erro($$select * from public.eventos_invalidos$$, 'permission denied', 'membro não lê eventos');
reset role;
set role anon;
select teste.erro($$select public.relatar_invalidos('77', array['F4A2'])$$, 'permission denied', 'anônimo não relata');
reset role;
-- o banco também recusa estados incoerentes
select teste.erro($$insert into public.relatos_invalidos (plataforma, codigo, usuario_id, associacao, qualificado) values ('77','X','f4_b','sem_copia',true)$$,
                  'relatos_invalidos_associacao_check', 'banco recusa relato "qualificado" sem cópia');

delete from public.codigos where plataforma = '77';
select 'TODOS OS TESTES DE CÓDIGOS INVÁLIDOS PASSARAM';
