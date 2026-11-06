-- Testes de segurança do sistema de membros (rodar DEPOIS da migração 001).
\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned

-- ---------- 1. Dados existentes preservados ----------
select teste.ok((select usuarios from teste.antes) = (select count(*) from public.usuarios), 'mesmo número de usuários');
select teste.ok((select codigos  from teste.antes) = (select count(*) from public.codigos),  'mesmo número de códigos');
select teste.ok((select copias   from teste.antes) = (select count(*) from public.copias),   'mesmo número de cópias');
select teste.ok((select usuarios_lista from teste.antes) =
                (select string_agg(id || ':' || nome, ',' order by id) from public.usuarios), 'ids e nomes intactos');
select teste.ok((select codigos_lista from teste.antes) =
                (select string_agg(plataforma || ':' || codigo || ':' || autor_id || ':' || criado_em, ',' order by id) from public.codigos),
                'códigos intactos (incl. datas)');
select teste.ok((select copias_lista from teste.antes) =
                (select string_agg(codigo_id || ':' || usuario_id, ',' order by codigo_id, usuario_id) from public.copias), 'cópias intactas');
select teste.ok(not exists (select 1 from public.usuarios where papel <> 'pendente'), 'usuários existentes ficaram pendentes');

-- ---------- 2. Primeiro admin ----------
select teste.erro($$select public.definir_primeiro_admin('ninguem')$$, 'usuario_inexistente', 'primeiro admin exige usuário existente');
select public.definir_primeiro_admin('anderson');
select teste.erro($$select public.definir_primeiro_admin('pedro')$$, 'ja_existe_admin', 'primeiro admin só funciona uma vez');

set role authenticated;
select teste.como('u_pedro', 'pedro');
select teste.erro($$select public.definir_primeiro_admin('pedro')$$, 'permission denied', 'site não consegue chamar definir_primeiro_admin');
reset role;

-- ---------- 3. Pendente: não vê nem faz nada de membro ----------
set role authenticated;
select teste.como('u_pedro', 'pedro');
select teste.ok((public.entrar() ->> 'papel') = 'pendente' and (public.entrar() ->> 'acesso')::boolean = false, 'entrar() informa pendente sem acesso');
select teste.ok(teste.contar('select * from public.codigos') = 0,        'pendente não lê codigos');
select teste.ok(teste.contar('select * from public.copias') = 0,         'pendente não lê copias');
select teste.ok(teste.contar('select * from public.codigos_ativos') = 0, 'pendente não lê codigos_ativos');
select teste.ok(teste.contar('select * from public.ranking') = 0,        'pendente não lê ranking');
select teste.ok(teste.contar('select * from public.eventos_acesso') = 0, 'pendente não lê auditoria');
select teste.ok(teste.contar('select * from public.usuarios') = 1,       'pendente só vê a própria linha');
select teste.erro($$select public.postar_codigos('777', array['X1'])$$, 'acesso_negado', 'pendente não posta');
select teste.erro($$select public.copiar_codigo(1)$$,                  'acesso_negado', 'pendente não copia');
select teste.erro($$select public.apagar_codigo(1)$$,                  'acesso_negado', 'pendente não apaga');
select teste.erro($$select public.admin_alterar_acesso('u_luis','aprovar')$$, 'nao_admin', 'pendente não aprova ninguém');
select teste.erro($$update public.usuarios set papel = 'admin' where id = 'u_pedro'$$, 'permission denied', 'pendente não se promove direto na tabela');
select teste.erro($$insert into public.eventos_acesso (alvo_id, acao) values ('u_pedro','aprovou')$$, 'permission denied', 'pendente não grava auditoria');
reset role;

-- ---------- 4. Conta nova pelo Clerk: vira pendente sozinha ----------
set role authenticated;
select teste.como('u_novo', 'novato');
select teste.ok((public.entrar() ->> 'papel') = 'pendente', 'conta nova entra como pendente');
reset role;
select teste.ok(exists (select 1 from public.eventos_acesso where alvo_id = 'u_novo' and acao = 'solicitou'), 'solicitação registrada na auditoria');

-- ---------- 5. Problemas de login com mensagens claras ----------
set role authenticated;
select teste.como('u_semnome');
select teste.erro($$select public.entrar()$$, 'sem_username_no_token', 'token sem username');
select teste.como('u_outro', 'pedro');
select teste.erro($$select public.entrar()$$, 'nome_em_uso', 'username já usado por outra conta');
select teste.como('u_ruim', 'nome com espaço');
select teste.erro($$select public.entrar()$$, 'username_invalido', 'username fora do padrão');
select set_config('request.jwt.claims', '', false);
select teste.erro($$select public.entrar()$$, 'nao_logado', 'sem token');
reset role;

set role anon;
select teste.erro($$select * from public.codigos$$, 'permission denied', 'anônimo não lê codigos');
select teste.erro($$select public.entrar()$$, 'permission denied', 'anônimo não chama entrar()');
reset role;

-- ---------- 6. Admin aprova, rejeita, suspende, reativa ----------
set role authenticated;
select teste.como('u_anderson', 'anderson');
select teste.ok((public.entrar() ->> 'papel') = 'admin', 'anderson é admin');
select teste.ok(teste.contar('select * from public.usuarios') = 4, 'admin vê todos os usuários, inclusive pendentes');
select teste.ok((public.admin_alterar_acesso('u_pedro', 'aprovar') ->> 'papel') = 'membro', 'admin aprova pedro');
select teste.ok((public.admin_alterar_acesso('u_luis',  'aprovar') ->> 'papel') = 'membro', 'admin aprova luis');
select teste.ok((public.admin_alterar_acesso('u_novo', 'rejeitar', 'não conheço') ->> 'situacao') = 'rejeitado', 'admin rejeita novato');
select teste.erro($$select public.admin_alterar_acesso('u_pedro', 'aprovar')$$, 'acao_invalida', 'não aprova quem já é membro');
select teste.erro($$select public.admin_alterar_acesso('u_anderson', 'suspender')$$, 'nao_pode_alterar_a_si_mesmo', 'admin não altera a si mesmo');
select teste.erro($$select public.admin_alterar_acesso('u_pedro', 'virar_deus')$$, 'acao_invalida', 'ação desconhecida');
select teste.erro($$select public.admin_alterar_acesso('u_x', 'aprovar')$$, 'usuario_inexistente', 'alvo inexistente');
select teste.erro($$select public.admin_alterar_acesso('u_luis', 'suspender', repeat('x', 301))$$, 'motivo_longo', 'motivo limitado a 300');
reset role;

-- rejeitado continua sem acesso, e pode ser aprovado depois
set role authenticated;
select teste.como('u_novo', 'novato');
select teste.ok((public.entrar() ->> 'situacao') = 'rejeitado', 'rejeitado vê o próprio estado');
select teste.ok(teste.contar('select * from public.codigos') = 0, 'rejeitado não lê codigos');
reset role;

-- ---------- 7. Membro: vê os dados, mas não administra ----------
set role authenticated;
select teste.como('u_pedro', 'pedro');
select teste.ok((public.entrar() ->> 'acesso')::boolean, 'pedro agora tem acesso');
select teste.ok(teste.contar('select * from public.codigos') = 3, 'membro lê codigos (histórico preservado)');
select teste.ok(teste.contar('select * from public.ranking') = 3, 'ranking só com membros ativos (anderson, pedro, luis)');
select teste.ok(teste.contar('select * from public.usuarios') = 3, 'membro não vê pendentes nem rejeitados');
select teste.ok(teste.contar('select * from public.eventos_acesso') = 0, 'membro não lê auditoria');
select teste.erro($$select public.admin_alterar_acesso('u_novo','aprovar')$$, 'nao_admin', 'membro não aprova');
select teste.erro($$select public.admin_alterar_acesso('u_luis','promover_admin')$$, 'nao_admin', 'membro não promove admin');
select teste.ok((public.postar_codigos('777', array['NOVO1']) ->> 'adicionados')::int = 1, 'membro posta');
reset role;

-- ---------- 8. Suspensão corta o acesso na hora ----------
set role authenticated;
select teste.como('u_anderson', 'anderson');
select public.admin_alterar_acesso('u_luis', 'suspender', 'teste');
select teste.como('u_luis', 'luis');
select teste.ok(teste.contar('select * from public.codigos') = 0, 'suspenso não lê codigos');
select teste.erro($$select public.copiar_codigo((select 1))$$, 'acesso_negado', 'suspenso não copia');
select teste.como('u_anderson', 'anderson');
select teste.ok((public.admin_alterar_acesso('u_luis', 'reativar') ->> 'situacao') = 'ativo', 'admin reativa luis');
reset role;

-- ---------- 9. Vários admins, sem ficar sem nenhum ----------
set role authenticated;
select teste.como('u_anderson', 'anderson');
select teste.ok((public.admin_alterar_acesso('u_pedro', 'promover_admin') ->> 'papel') = 'admin', 'anderson promove pedro');
select teste.como('u_pedro', 'pedro');
select teste.ok(teste.contar('select * from public.eventos_acesso') > 0, 'novo admin lê auditoria');
select teste.ok((public.admin_alterar_acesso('u_anderson', 'remover_admin') ->> 'papel') = 'membro', 'pedro remove admin de anderson');
select teste.como('u_anderson', 'anderson');
select teste.erro($$select public.admin_alterar_acesso('u_pedro','remover_admin')$$, 'nao_admin', 'ex-admin perde poderes na hora');
select teste.como('u_pedro', 'pedro');
select teste.erro($$select public.admin_alterar_acesso('u_pedro','remover_admin')$$, 'nao_pode_alterar_a_si_mesmo', 'último admin não se remove');
select public.admin_alterar_acesso('u_anderson', 'promover_admin');
reset role;

select teste.ok((select count(*) from public.eventos_acesso where por_id is not null) >= 8, 'todas as ações de admin auditadas com autor');
select teste.ok(not exists (select 1 from public.eventos_acesso e where e.acao in ('aprovou','rejeitou','suspendeu','reativou','promoveu_admin','removeu_admin') and e.por_id is null),
                'nenhuma ação de admin sem autor');

-- ---------- 10. Regras de código continuam iguais ----------
set role authenticated;
select teste.como('u_luis', 'luis');
select teste.ok(public.copiar_codigo((select id from public.codigos where codigo = 'NOVO1')), 'membro copia código de outro');
select teste.ok(not public.copiar_codigo((select id from public.codigos where codigo = 'NOVO1')), 'não copia duas vezes');
select teste.como('u_pedro', 'pedro');
select teste.ok(not public.copiar_codigo((select id from public.codigos where codigo = 'NOVO1')), 'autor não copia o próprio');
reset role;

-- ---------- 11. Versão esperada: não sobrescreve decisão de outro admin ----------
insert into public.usuarios (id, nome) values ('u_versao', 'versao');
set role authenticated;
select teste.como('u_anderson', 'anderson');
select teste.erro($$select public.admin_alterar_acesso('u_versao', 'aprovar', null, now() - interval '1 day')$$,
                  'estado_mudou', 'ação com versão antiga é recusada');
select teste.ok((public.admin_alterar_acesso('u_versao', 'aprovar', null,
                 (select atualizado_em from public.usuarios where id = 'u_versao')) ->> 'papel') = 'membro',
                'ação com versão atual é aceita');
reset role;

select 'TODOS OS TESTES DE MEMBROS PASSARAM';
