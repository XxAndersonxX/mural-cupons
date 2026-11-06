-- Dados "de produção" ANTES da migração 001, criados pelo fluxo antigo
-- (entrar/postar/copiar do supabase.sql original).
select teste.como('u_anderson', 'anderson'); set role authenticated; select public.entrar(); reset role;
select teste.como('u_pedro', 'pedro');       set role authenticated; select public.entrar(); reset role;
select teste.como('u_luis', 'luis');         set role authenticated; select public.entrar(); reset role;

select teste.como('u_pedro', 'pedro'); set role authenticated;
select public.postar_codigos('777', array['ANTIGO1', 'ANTIGO2', 'ANTIGO3']);
reset role;
select teste.como('u_luis', 'luis'); set role authenticated;
select public.copiar_codigo((select id from public.codigos where codigo = 'ANTIGO1'));
reset role;

-- foto dos dados para comparar depois
create table teste.antes as
select (select count(*) from public.usuarios) as usuarios,
       (select count(*) from public.codigos)  as codigos,
       (select count(*) from public.copias)   as copias,
       (select string_agg(id || ':' || nome, ',' order by id) from public.usuarios) as usuarios_lista,
       (select string_agg(plataforma || ':' || codigo || ':' || autor_id || ':' || criado_em, ',' order by id) from public.codigos) as codigos_lista,
       (select string_agg(codigo_id || ':' || usuario_id, ',' order by codigo_id, usuario_id) from public.copias) as copias_lista;
