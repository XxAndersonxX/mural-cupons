-- Testes da migração 002: cópia individual com motivo, lote, recuperação,
-- permissões e "aproveitados". Rodar DEPOIS da 002 (usa ids próprios "f2_").
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- ---------- preparação ----------
delete from public.codigos where plataforma = 'Sorte25';
insert into public.usuarios (id, nome, papel, situacao) values
  ('f2_autor', 'f2autor', 'membro', 'ativo'), ('f2_a', 'f2a', 'membro', 'ativo'),
  ('f2_b', 'f2b', 'membro', 'ativo'), ('f2_c', 'f2c', 'membro', 'ativo'), ('f2_d', 'f2d', 'membro', 'ativo'),
  ('f2_pend', 'f2pend', 'pendente', 'ativo'), ('f2_susp', 'f2susp', 'membro', 'suspenso');
insert into public.codigos (plataforma, codigo, autor_id, criado_em) values
  ('Sorte25', 'S1', 'f2_autor', now() - interval '10 hours'),
  ('Sorte25', 'S2', 'f2_autor', now() - interval '9 hours'),
  ('Sorte25', 'S3', 'f2_autor', now() - interval '8 hours'),
  ('Sorte25', 'S4', 'f2_autor', now() - interval '7 hours'),
  ('Sorte25', 'S5', 'f2_autor', now() - interval '6 hours'),
  ('Sorte25', 'S6', 'f2_autor', now() - interval '5 hours'),
  ('Sorte25', 'SX', 'f2_autor', now() - interval '49 hours'),   -- vencido
  ('Sorte25', 'SESG', 'f2_autor', now() - interval '11 hours'), -- vai ficar esgotado
  ('Sorte25', 'SA', 'f2_a', now() - interval '1 hour');         -- do f2_a
insert into public.copias (codigo_id, usuario_id)
select id, u from public.codigos, unnest(array['f2_b', 'f2_c', 'f2_d']) u where codigo = 'SESG';

create temp table ids as select codigo, id from public.codigos where plataforma = 'Sorte25';
grant select on ids to authenticated;
create temp table lotes (dono text, lote uuid);
grant select, insert on lotes to authenticated;

-- ---------- 1. Cópia individual: cada motivo ----------
set role authenticated;
select teste.como('f2_a', 'f2a');
select teste.ok(public.copiar_codigo_v2(-1)::jsonb = '{"status":"inexistente"}', 'v2: inexistente');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'SX'))::jsonb = '{"status":"expirado"}', 'v2: expirado não copia');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'SA'))::jsonb = '{"status":"proprio","codigo":"SA"}', 'v2: próprio devolve o código sem contar');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'S1'))::jsonb = '{"status":"registrado","codigo":"S1"}', 'v2: registrado');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'S1'))::jsonb = '{"status":"ja_copiado","codigo":"S1"}', 'v2: já copiado devolve o código sem contar');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'SESG'))::jsonb = '{"status":"esgotado"}', 'v2: esgotado não copia');
select teste.como('f2_b', 'f2b');
select teste.ok(public.copiar_codigo_v2((select id from ids where codigo = 'SESG'))::jsonb = '{"status":"ja_copiado","codigo":"SESG"}', 'v2: quem já pegou um esgotado pode recopiar');
reset role;
select teste.ok((select count(*) from public.copias where codigo_id = (select id from ids where codigo = 'S1')) = 1, 'v2: só 1 cópia registrada de S1');
select teste.ok((select count(*) from public.copias where codigo_id = (select id from ids where codigo = 'SA')) = 0, 'v2: autor não gerou cópia');
select teste.ok((select count(*) from public.copias where codigo_id = (select id from ids where codigo = 'SX')) = 0, 'v2: vencido não gerou cópia');

-- compatibilidade: função antiga continua igual
set role authenticated;
select teste.como('f2_a', 'f2a');
select teste.ok(public.copiar_codigo((select id from ids where codigo = 'S1')) = false, 'compat: copiar_codigo antigo devolve false para já copiado');
reset role;

-- ---------- 2. Lote: regras, ordem e retorno ----------
set role authenticated;
select teste.como('f2_b', 'f2b');
insert into lotes select 'f2_b', (public.pegar_lote('Sorte25', 3) ->> 'lote_id')::uuid;
reset role;
select teste.ok((select string_agg(c.codigo, ',' order by c.criado_em, c.id) from public.copias p join public.codigos c on c.id = p.codigo_id
                 where p.lote_id = (select lote from lotes where dono = 'f2_b')) = 'S1,S2,S3',
                'lote: 3 pedidos -> S1,S2,S3 (vencimento mais próximo primeiro; ignora vencido, esgotado e já pegos)');

set role authenticated;
select teste.como('f2_a', 'f2a');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(r -> 'codigos') x) = 'S2,S3,S4,S5,S6'
                and (r ->> 'registrados')::int = 5 and (r ->> 'pedidos')::int = 200,
                'lote: pede 200, recebe só os 5 elegíveis, na ordem (sem o próprio SA e sem S1 já pego)')
from (select public.pegar_lote('Sorte25', 200) r) t;

select teste.como('f2_c', 'f2c');
insert into lotes select 'f2_c', (public.pegar_lote('Sorte25', 10) ->> 'lote_id')::uuid;
select teste.como('f2_d', 'f2d');
insert into lotes select 'f2_d', (public.pegar_lote('Sorte25', 10) ->> 'lote_id')::uuid;
reset role;

select teste.ok((select count(*) from public.copias p where p.lote_id = (select lote from lotes where dono = 'f2_c')) = 7, 'lote f2_c: 7 registrados (S1..S6 + SA)');
select teste.ok((select string_agg(c.codigo, ',' order by c.criado_em, c.id) from public.copias p join public.codigos c on c.id = p.codigo_id
                 where p.lote_id = (select lote from lotes where dono = 'f2_d')) = 'S4,S5,S6,SA',
                'lote f2_d: só os que ainda tinham vaga (S1..S3 esgotaram)');
select teste.ok((select max(n) from (select count(*) n from public.copias where codigo_id in (select id from ids) group by codigo_id) t) = 3,
                'nenhum código passou de 3 cópias');

-- f2_d já pegou tudo o que podia: nada mais elegível para ele
set role authenticated;
select teste.como('f2_d', 'f2d');
select teste.ok(r::jsonb = jsonb_build_object('lote_id', null, 'pedidos', 5, 'registrados', 0, 'plataforma', 'Sorte25', 'codigos', '[]'::jsonb),
                'lote sem nada disponível: 0 registrados, lista vazia, sem lote')
from (select public.pegar_lote('Sorte25', 5) r) t;
select teste.ok((public.pegar_lote('XYZ', 5) ->> 'registrados')::int = 0, 'lote em plataforma inexistente: 0');
select teste.erro($$select public.pegar_lote('Sorte25', 0)$$,   'quantidade_invalida', 'lote: 0 é inválido');
select teste.erro($$select public.pegar_lote('Sorte25', 201)$$, 'quantidade_invalida', 'lote: 201 é inválido');
select teste.erro($$select public.pegar_lote('Sorte25', null)$$, 'quantidade_invalida', 'lote: nulo é inválido');
select teste.ok((public.pegar_lote('Sorte25', 200) ->> 'registrados')::int = 0, 'lote: 200 é aceito');
reset role;

-- ---------- 3. Recuperação: só leitura, só o dono, só 48 h ----------
create temp table antes_rec as select count(*) n from public.copias;
set role authenticated;
select teste.como('f2_c', 'f2c');
select teste.ok((public.recuperar_lote() ->> 'lote_id')::uuid = (select lote from lotes where dono = 'f2_c'), 'recuperar sem id: último lote do próprio usuário');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(public.recuperar_lote((select lote from lotes where dono = 'f2_c')) -> 'codigos') x)
                = 'S1,S2,S3,S4,S5,S6,SA', 'recuperar: mesma lista e mesma ordem');
select teste.ok(json_array_length(public.meus_lotes()) = 1 and (public.meus_lotes() -> 0 ->> 'registrados')::int = 7, 'meus_lotes: 1 lote com 7');
select teste.como('f2_b', 'f2b');
select teste.erro($$select public.recuperar_lote((select lote from lotes where dono = 'f2_c'))$$, 'lote_nao_encontrado', 'recuperar lote de outra pessoa: negado');
reset role;
select teste.ok((select count(*) from public.copias) = (select n from antes_rec), 'recuperar e meus_lotes não registram cópias');

-- lote com mais de 48 h some
update public.copias set criado_em = now() - interval '49 hours' where lote_id = (select lote from lotes where dono = 'f2_b');
set role authenticated;
select teste.como('f2_b', 'f2b');
select teste.erro($$select public.recuperar_lote((select lote from lotes where dono = 'f2_b'))$$, 'lote_nao_encontrado', 'recuperar lote com mais de 48 h: negado');
select teste.ok(json_array_length(public.meus_lotes()) = 0, 'meus_lotes: só últimas 48 h');
reset role;

-- código apagado some do lote (respeita exclusões)
delete from public.codigos where codigo = 'S6' and plataforma = 'Sorte25';
set role authenticated;
select teste.como('f2_d', 'f2d');
select teste.ok((public.recuperar_lote() ->> 'registrados')::int = 3, 'recuperar: código apagado sai do lote');
reset role;

-- ---------- 4. Permissões ----------
set role authenticated;
select teste.como('f2_pend', 'f2pend');
select teste.erro($$select public.copiar_codigo_v2(1)$$,              'acesso_negado', 'pendente: v2 negado');
select teste.erro($$select public.pegar_lote('Sorte25', 1)$$,         'acesso_negado', 'pendente: lote negado');
select teste.erro($$select public.recuperar_lote()$$,                'acesso_negado', 'pendente: recuperar negado');
select teste.erro($$select public.meus_lotes()$$,                    'acesso_negado', 'pendente: meus_lotes negado');
select teste.como('f2_susp', 'f2susp');
select teste.erro($$select public.pegar_lote('Sorte25', 1)$$,         'acesso_negado', 'suspenso: lote negado');
select teste.erro($$select public.recuperar_lote()$$,                'acesso_negado', 'suspenso: recuperar negado');
select teste.erro($$select public.resumo_lote(gen_random_uuid(), 1)$$, 'permission denied', 'resumo_lote é interna');
select teste.erro($$update public.copias set lote_id = null$$,         'permission denied', 'ninguém altera lote_id direto');
reset role;
set role anon;
select teste.erro($$select public.pegar_lote('Sorte25', 1)$$, 'permission denied', 'anônimo: lote negado');
reset role;

-- ---------- 5. Aproveitados ----------
set role authenticated;
select teste.como('f2_a', 'f2a');
select teste.ok((select postados = 7 and aproveitados = 6 from public.ranking where id = 'f2_autor'),
                'aproveitados f2autor: 6 de 7 publicados (S1..S5 e SESG; SX não; cada um conta 1 vez)');
select teste.ok((select postados = 1 and aproveitados = 1 from public.ranking where id = 'f2_a'), 'aproveitados f2a: SA pego por 2 conta 1');
select teste.ok((select aproveitados = 0 from public.ranking where id = 'f2_b'), 'aproveitados: quem não publicou tem 0');
select teste.ok((select array_agg(column_name::text order by ordinal_position) from information_schema.columns
                 where table_schema = 'public' and table_name = 'ranking')
                = array['id','nome','criado_em','postados','copiados','ativos','aproveitados'], 'ranking: colunas antigas mantidas, aproveitados no fim');
reset role;

-- limpeza dos dados de teste da fase 2
delete from public.codigos where plataforma = 'Sorte25';
select 'TODOS OS TESTES DA FASE 2 PASSARAM';
