-- Testes da migração 003: distribuição híbrida do lote.
-- Rodar DEPOIS da 003. Usa só a plataforma BRA365 e usuários "f3_".
--
-- Além das contagens exatas dos exemplos, cada lote é conferido contra as
-- PROPRIEDADES que definem o critério (teste.f3_confere):
--   P0 todo código do lote era elegível antes do pedido
--   P1 dentro de cada autor, o lote leva exatamente os mais antigos (prefixo)
--   P2 total = menor entre o pedido e o número de elegíveis
--   P3 equilíbrio: se o autor A ainda tinha código sobrando, nenhum outro
--      autor recebeu mais que (o que A recebeu + 1)
--   P4 desempate: se B recebeu 1 a mais que A (e A tinha sobra), o último
--      código de B é mais antigo (criado_em, id) que o próximo de A
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- ---------- preparação ----------
insert into public.usuarios (id, nome, papel, situacao) values
  ('f3_u', 'f3u', 'membro', 'ativo'), ('f3_v', 'f3v', 'membro', 'ativo'),
  ('f3_anderson', 'f3anderson', 'membro', 'ativo'), ('f3_cafe', 'f3cafe', 'membro', 'ativo'),
  ('f3_panda', 'f3panda', 'membro', 'ativo'), ('f3_joao', 'f3joao', 'membro', 'ativo'),
  ('f3_a5', 'f3a5', 'membro', 'ativo'), ('f3_a6', 'f3a6', 'membro', 'ativo'),
  ('f3_x1', 'f3x1', 'membro', 'ativo'), ('f3_x2', 'f3x2', 'membro', 'ativo'), ('f3_x3', 'f3x3', 'membro', 'ativo'),
  ('f3_pend', 'f3pend', 'pendente', 'ativo'), ('f3_susp', 'f3susp', 'membro', 'suspenso');

create table teste.f3_pre (id bigint, autor_id text, criado_em timestamptz);
create table teste.f3_lotes (rotulo text, lote uuid, resposta json);
grant select, insert on teste.f3_lotes to authenticated;

-- limpa a plataforma de teste
create function teste.f3_limpa() returns void language sql as $$
  delete from public.codigos where plataforma = 'BRA365';
$$;
-- qtd códigos do autor; o 1º (mais antigo) com idade p_inicio, os seguintes
-- p_passo mais novos cada um
create function teste.f3_codigos(p_autor text, p_qtd int, p_inicio interval, p_passo interval default '10 minutes')
returns void language sql as $$
  insert into public.codigos (plataforma, codigo, autor_id, criado_em)
  select 'BRA365', replace(p_autor, 'f3_', '') || '_' || lpad(j::text, 3, '0'), p_autor,
         now() - p_inicio + (j - 1) * p_passo
    from generate_series(1, p_qtd) j;
$$;
-- foto dos elegíveis para p_usuario, calculada de forma independente
create function teste.f3_foto(p_usuario text) returns void language sql as $$
  delete from teste.f3_pre;
  insert into teste.f3_pre
  select c.id, c.autor_id, c.criado_em from public.codigos c
   where c.plataforma = 'BRA365' and c.autor_id <> p_usuario
     and c.criado_em > now() - interval '48 hours'
     and not exists (select 1 from public.copias x where x.codigo_id = c.id and x.usuario_id = p_usuario)
     and (select count(*) from public.copias x where x.codigo_id = c.id) < 3;
$$;

create function teste.f3_confere(p_lote uuid, p_n int, p_rotulo text) returns text language plpgsql
set client_min_messages = warning as $$
declare v_e int; v_sel int; v_ruim int;
begin
  create temp table if not exists f3_sel (id bigint) on commit drop;
  delete from f3_sel;
  insert into f3_sel select codigo_id from public.copias where p_lote is not null and lote_id = p_lote;

  -- P0
  select count(*) into v_ruim from f3_sel s where not exists (select 1 from teste.f3_pre p where p.id = s.id);
  if v_ruim > 0 then raise exception 'FALHOU: % — P0: % código(s) não elegível(is) no lote', p_rotulo, v_ruim; end if;

  create temp table if not exists f3_ord (id bigint, autor_id text, criado_em timestamptz, ordem int, escolhido boolean) on commit drop;
  delete from f3_ord;
  insert into f3_ord
  select p.id, p.autor_id, p.criado_em,
         row_number() over (partition by p.autor_id order by p.criado_em, p.id),
         exists (select 1 from f3_sel s where s.id = p.id)
    from teste.f3_pre p;

  -- P1: escolhidos de cada autor = prefixo da fila dele
  select count(*) into v_ruim from f3_ord o
   where o.escolhido and o.ordem > (select count(*) from f3_ord o2 where o2.autor_id = o.autor_id and o2.escolhido);
  if v_ruim > 0 then raise exception 'FALHOU: % — P1: código mais novo escolhido com mais antigo do mesmo autor disponível', p_rotulo; end if;

  -- P2
  select count(*) into v_e from teste.f3_pre;
  select count(*) into v_sel from f3_sel;
  if v_sel <> least(p_n, v_e) then raise exception 'FALHOU: % — P2: % registrados, esperado %', p_rotulo, v_sel, least(p_n, v_e); end if;

  -- P3 e P4
  with por_autor as (
    select autor_id, count(*) n, count(*) filter (where escolhido) c from f3_ord group by autor_id
  )
  select count(*) into v_ruim
    from por_autor a join por_autor b on a.autor_id <> b.autor_id
   where a.c < a.n
     and (b.c > a.c + 1
          or (b.c = a.c + 1 and
              (select (o.criado_em, o.id) from f3_ord o where o.autor_id = b.autor_id and o.ordem = b.c)
              > (select (o.criado_em, o.id) from f3_ord o where o.autor_id = a.autor_id and o.ordem = a.c + 1)));
  if v_ruim > 0 then raise exception 'FALHOU: % — P3/P4: distribuição desequilibrada ou desempate errado', p_rotulo; end if;

  return 'ok  ' || p_rotulo;
end $$;

-- pede o lote como p_usuario (pelo papel authenticated) e confere as propriedades
create function teste.f3_pede(p_usuario text, p_n int, p_rotulo text) returns text language plpgsql as $$
declare r json;
begin
  perform teste.f3_foto(p_usuario);
  perform teste.como(p_usuario, replace(p_usuario, '_', ''));
  set local role authenticated;
  r := public.pegar_lote('BRA365', p_n);
  reset role;
  insert into teste.f3_lotes values (p_rotulo, (r ->> 'lote_id')::uuid, r);
  return teste.f3_confere((r ->> 'lote_id')::uuid, p_n, p_rotulo);
end $$;

-- quantos códigos de cada autor entraram no lote do rótulo
create function teste.f3_contagem(p_rotulo text) returns text language sql as $$
  select string_agg(replace(a.autor, 'f3_', '') || '=' || coalesce(n, 0), ' ' order by a.ordem)
    from unnest(array['f3_anderson','f3_cafe','f3_panda','f3_joao','f3_a5','f3_a6']) with ordinality a(autor, ordem)
    left join (select c.autor_id, count(*) n from public.copias p join public.codigos c on c.id = p.codigo_id
                where p.lote_id = (select lote from teste.f3_lotes where rotulo = p_rotulo) group by c.autor_id) t
      on t.autor_id = a.autor
   where a.autor in ('f3_anderson','f3_cafe','f3_panda','f3_joao') or n > 0;
$$;

-- ---------- 1. Exemplos da especificação (N = 60) ----------
select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 10, '40 hours'), teste.f3_codigos('f3_cafe', 10, '39 hours'),
       teste.f3_codigos('f3_panda', 70, '45 hours'),    teste.f3_codigos('f3_joao', 10, '37 hours');  -- Panda tem os mais antigos
select teste.f3_pede('f3_u', 60, 'Ex1: propriedades');
select teste.ok(teste.f3_contagem('Ex1: propriedades') = 'anderson=10 cafe=10 panda=30 joao=10', 'Ex1 (10/10/70/10): 10/10/30/10');

select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 10, '40 hours'), teste.f3_codigos('f3_cafe', 10, '39 hours'),
       teste.f3_codigos('f3_panda', 60, '45 hours'),    teste.f3_codigos('f3_joao', 20, '37 hours');  -- Panda tem os mais antigos
select teste.f3_pede('f3_u', 60, 'Ex2: propriedades');
select teste.ok(teste.f3_contagem('Ex2: propriedades') = 'anderson=10 cafe=10 panda=20 joao=20', 'Ex2 (10/10/60/20): 10/10/20/20');

-- Ex3: 5 + 18 + 18 + 18 = 59; a 60ª vaga vai para quem tem o 19º código
-- mais antigo. Mesmo passo para todos: quem começou antes tem o 19º mais antigo.
select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 5, '40 hours'), teste.f3_codigos('f3_cafe', 20, '39 hours 2 minutes'),
       teste.f3_codigos('f3_panda', 60, '39 hours 1 minute'), teste.f3_codigos('f3_joao', 25, '39 hours');
select teste.f3_pede('f3_u', 60, 'Ex3a: propriedades');
select teste.ok(teste.f3_contagem('Ex3a: propriedades') = 'anderson=5 cafe=19 panda=18 joao=18', 'Ex3 (5/20/60/25), 19º do Café mais antigo: 5/19/18/18');

select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 5, '40 hours'), teste.f3_codigos('f3_cafe', 20, '39 hours'),
       teste.f3_codigos('f3_panda', 60, '39 hours 2 minutes'), teste.f3_codigos('f3_joao', 25, '39 hours 1 minute');
select teste.f3_pede('f3_u', 60, 'Ex3b: propriedades');
select teste.ok(teste.f3_contagem('Ex3b: propriedades') = 'anderson=5 cafe=18 panda=19 joao=18', 'Ex3 (5/20/60/25), 19º do Panda mais antigo: 5/18/19/18');

-- a ordem do 1º código não decide o desempate; decide o PRÓXIMO (19º):
-- João começa mais tarde, mas posta mais rápido -> seu 19º é o mais antigo
select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 5, '40 hours'), teste.f3_codigos('f3_cafe', 20, '39 hours'),
       teste.f3_codigos('f3_panda', 60, '39 hours 30 minutes'), teste.f3_codigos('f3_joao', 25, '37 hours', '1 minute');
select teste.f3_pede('f3_u', 60, 'Ex3c: propriedades');
select teste.ok(teste.f3_contagem('Ex3c: propriedades') = 'anderson=5 cafe=18 panda=18 joao=19', 'Ex3: desempate pelo PRÓXIMO código mais antigo (João: 5/18/18/19)');

-- empate total de idade no próximo código -> menor id
select teste.f3_limpa();
insert into public.codigos (plataforma, codigo, autor_id, criado_em)
select 'BRA365', 'EMP_' || a || '_' || j, a, date_trunc('hour', now()) - interval '10 hours' + j * interval '1 minute'
  from unnest(array['f3_cafe', 'f3_panda']) a, generate_series(1, 3) j;
select teste.f3_pede('f3_u', 3, 'empate de idade: propriedades');
select teste.ok(teste.f3_contagem('empate de idade: propriedades') = 'anderson=0 cafe=2 panda=1 joao=0', 'empate exato de idade: menor id (Café, inserido antes) leva a sobra');

-- ---------- 2. Casos de borda ----------
-- divisão não exata: 3 autores x 20, pede 10 -> 4/3/3; a sobra para o mais antigo
select teste.f3_limpa();
select teste.f3_codigos('f3_cafe', 20, '20 hours'), teste.f3_codigos('f3_panda', 20, '21 hours'), teste.f3_codigos('f3_joao', 20, '19 hours');
select teste.f3_pede('f3_u', 10, 'não divisível: propriedades');
select teste.ok(teste.f3_contagem('não divisível: propriedades') = 'anderson=0 cafe=3 panda=4 joao=3', 'não divisível (10 em 3): 4/3/3, extra para o Panda (mais antigo)');

-- um autor só: os 7 mais antigos, em ordem
select teste.f3_limpa();
select teste.f3_codigos('f3_panda', 10, '20 hours');
select teste.f3_pede('f3_u', 7, 'um autor: propriedades');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(
                   (select resposta from teste.f3_lotes where rotulo = 'um autor: propriedades') -> 'codigos') x)
                = 'panda_001,panda_002,panda_003,panda_004,panda_005,panda_006,panda_007', 'um autor só: os 7 mais antigos');

-- mais autores que o pedido: 6 autores, pede 3 -> 1 de cada um dos 3 cujo 1º código é mais antigo
select teste.f3_limpa();
select teste.f3_codigos('f3_anderson', 5, '10 hours'), teste.f3_codigos('f3_cafe', 5, '12 hours'),
       teste.f3_codigos('f3_panda', 5, '14 hours'),    teste.f3_codigos('f3_joao', 5, '11 hours'),
       teste.f3_codigos('f3_a5', 5, '13 hours'),       teste.f3_codigos('f3_a6', 5, '9 hours');
select teste.f3_pede('f3_u', 3, 'mais autores que pedido: propriedades');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(
                   (select resposta from teste.f3_lotes where rotulo = 'mais autores que pedido: propriedades') -> 'codigos') x)
                = 'panda_001,a5_001,cafe_001', 'mais autores que o pedido: 1 de cada, os 3 autores de código mais antigo');

-- pede mais que o disponível: leva tudo
select teste.f3_limpa();
select teste.f3_codigos('f3_cafe', 4, '10 hours'), teste.f3_codigos('f3_panda', 2, '11 hours');
select teste.f3_pede('f3_u', 200, 'pede 200 com 6: propriedades');

-- próprios, já copiados, vencidos e esgotados ficam fora — e não contam como
-- "mais antigo disponível" (o lote pula para o próximo elegível do autor)
select teste.f3_limpa();
select teste.f3_codigos('f3_cafe', 6, '50 hours'),        -- cafe_001..006: 50h..49h10 -> vencidos
       teste.f3_codigos('f3_panda', 6, '20 hours'),
       teste.f3_codigos('f3_u', 5, '30 hours'),           -- próprios
       teste.f3_codigos('f3_joao', 3, '25 hours');
insert into public.codigos (plataforma, codigo, autor_id, criado_em) values
  ('BRA365', 'cafe_ok1', 'f3_cafe', now() - interval '5 hours'), ('BRA365', 'cafe_ok2', 'f3_cafe', now() - interval '4 hours');
insert into public.copias (codigo_id, usuario_id)                              -- panda_001 esgotado
select id, x from public.codigos, unnest(array['f3_x1','f3_x2','f3_x3']) x where codigo = 'panda_001' and plataforma = 'BRA365';
insert into public.copias (codigo_id, usuario_id)                              -- panda_002 com 2 cópias (ainda elegível)
select id, x from public.codigos, unnest(array['f3_x1','f3_x2']) x where codigo = 'panda_002' and plataforma = 'BRA365';
insert into public.copias (codigo_id, usuario_id)                              -- joao_001 já copiado por f3_u
select id, 'f3_u' from public.codigos where codigo = 'joao_001' and plataforma = 'BRA365';
select teste.f3_pede('f3_u', 6, 'filtros: propriedades');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(
                   (select resposta from teste.f3_lotes where rotulo = 'filtros: propriedades') -> 'codigos') x)
                = 'joao_002,joao_003,panda_002,panda_003,cafe_ok1,cafe_ok2',
                'ignora vencidos, próprios, esgotado e já copiado; 2 de cada; lista em ordem global de vencimento');
select teste.ok((select count(*) from public.copias where codigo_id = (select id from public.codigos where codigo = 'panda_002' and plataforma = 'BRA365')) = 3,
                'código com 2 cópias recebe a 3ª e esgota');

-- dentro do autor, o mais antigo SEMPRE vem primeiro: f3_v pega depois e
-- recebe os seguintes de cada autor, nunca pulando um elegível
select teste.f3_pede('f3_v', 4, 'segundo usuário: propriedades');

-- limite de 3: três outros usuários esgotam um código; nenhum lote passa disso
select teste.f3_limpa();
select teste.f3_codigos('f3_cafe', 2, '10 hours');
select teste.f3_pede('f3_x1', 5, 'limite 3 (1)');
select teste.f3_pede('f3_x2', 5, 'limite 3 (2)');
select teste.f3_pede('f3_x3', 5, 'limite 3 (3)');
select teste.f3_pede('f3_u', 5, 'limite 3 (4): nada');
select teste.ok((select max(n) from (select count(*) n from public.copias p join public.codigos c on c.id = p.codigo_id
                  where c.plataforma = 'BRA365' group by p.codigo_id) t) = 3
                and (select resposta ->> 'registrados' from teste.f3_lotes where rotulo = 'limite 3 (4): nada') = '0',
                'limite de 3 pessoas por código mantido; o 4º recebe 0');

-- ---------- 3. Retorno, recuperação e formato ----------
select teste.f3_limpa();
select teste.f3_codigos('f3_cafe', 3, '10 hours'), teste.f3_codigos('f3_panda', 3, '10 hours 5 minutes');
select teste.f3_pede('f3_u', 4, 'recuperação: propriedades');
create temp table f3_antes_rec as select count(*) n from public.copias;
grant select on f3_antes_rec to authenticated;
select teste.como('f3_u', 'f3u');
set role authenticated;
select teste.ok((public.recuperar_lote((select lote from teste.f3_lotes where rotulo = 'recuperação: propriedades')) -> 'codigos')::jsonb
                = (select resposta -> 'codigos' from teste.f3_lotes where rotulo = 'recuperação: propriedades')::jsonb,
                'recuperar_lote devolve exatamente a mesma lista do pedido');
select teste.ok(json_array_length(public.recuperar_lote() -> 'codigos') = 4, 'recuperar o último lote: 4 códigos');
reset role;
select teste.ok((select count(*) from public.copias) = (select n from f3_antes_rec), 'recuperar não registra cópias');
select teste.ok((select string_agg(x ->> 'codigo', ',') from json_array_elements(
                   (select resposta from teste.f3_lotes where rotulo = 'recuperação: propriedades') -> 'codigos') x)
                = 'panda_001,cafe_001,panda_002,cafe_002', 'lista em ordem global (mais antigo primeiro), não agrupada por autor');
select teste.ok((select string_agg(k, ',' order by k)
                   from json_object_keys((select resposta from teste.f3_lotes where rotulo = 'recuperação: propriedades')) k)
                = 'codigos,criado_em,lote_id,pedidos,plataforma,registrados', 'formato da resposta igual ao da 002');

-- ---------- 4. Permissões e validação (inalteradas) ----------
select teste.como('f3_pend', 'f3pend');
set role authenticated;
select teste.erro($$select public.pegar_lote('BRA365', 1)$$, 'acesso_negado', 'pendente: lote negado');
select teste.como('f3_susp', 'f3susp');
select teste.erro($$select public.pegar_lote('BRA365', 1)$$, 'acesso_negado', 'suspenso: lote negado');
select teste.como('f3_u', 'f3u');
select teste.erro($$select public.pegar_lote('BRA365', 0)$$,   'quantidade_invalida', 'lote: 0 é inválido');
select teste.erro($$select public.pegar_lote('BRA365', 201)$$, 'quantidade_invalida', 'lote: 201 é inválido');
select teste.ok(r::jsonb = jsonb_build_object('lote_id', null, 'pedidos', 5, 'registrados', 0, 'plataforma', 'XYZ', 'codigos', '[]'::jsonb),
                'plataforma sem códigos: 0, sem lote')
from (select public.pegar_lote('XYZ', 5) r) t;
reset role;
set role anon;
select teste.erro($$select public.pegar_lote('BRA365', 1)$$, 'permission denied', 'anônimo: lote negado');
reset role;

-- ---------- 5. Casos aleatórios contra as propriedades ----------
-- 300 cenários: 1 a 6 autores, 0 a 40 códigos cada, idades sorteadas,
-- próprios, vencidos, esgotados, parcialmente copiados e já copiados; N de 1 a 200
do $$
declare
  i int; a text; v_n int; v_lote uuid;
  autores text[] := array['f3_anderson','f3_cafe','f3_panda','f3_joao','f3_a5','f3_a6'];
begin
  perform setseed(0.303);
  for i in 1 .. 300 loop
    perform teste.f3_limpa();
    foreach a in array autores[1 : 1 + floor(random() * 6)::int] loop
      insert into public.codigos (plataforma, codigo, autor_id, criado_em)
      select 'BRA365', 'R' || i || '_' || replace(a, 'f3_', '') || '_' || j, a,
             now() - (random() * 50) * interval '1 hour'               -- ~4% vencidos
        from generate_series(1, floor(random() * 41)::int) j;
    end loop;
    insert into public.codigos (plataforma, codigo, autor_id, criado_em)      -- próprios
    select 'BRA365', 'R' || i || '_u_' || j, 'f3_u', now() - random() * interval '40 hours' from generate_series(1, 3) j;
    insert into public.copias (codigo_id, usuario_id)                         -- cópias anteriores
    select c.id, x from public.codigos c, unnest(array['f3_x1','f3_x2','f3_x3','f3_u']) x
     where c.plataforma = 'BRA365' and c.autor_id <> 'f3_u' and random() < 0.25
    on conflict do nothing;
    v_n := 1 + floor(random() * 200)::int;
    perform teste.f3_pede('f3_u', v_n, 'aleatório ' || i);
  end loop;
end $$;
select 'ok  300 cenários aleatórios: P0–P4 valem em todos';

select teste.f3_limpa();
select 'TODOS OS TESTES DA DISTRIBUIÇÃO HÍBRIDA PASSARAM';
