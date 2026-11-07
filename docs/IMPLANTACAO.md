# Implantação da migração 001 (sistema de membros)

Guia para aplicar `migrations/001_membros.sql` no Supabase e publicar o site novo, sem ficar sem acesso. Leia tudo antes de começar. Leva uns 15 minutos.

## O que muda para quem usa

- Quem já tinha conta passa a ser **pendente**, até um admin aprovar. Nenhum código, cópia, id ou data é alterado.
- Contas novas continuam sendo criadas pelo Clerk, sem limite de quantidade no mural. Elas entram como **pendentes**.
- Pendentes, recusados e suspensos não leem nada pela API: cupons, cópias, ranking, usuários e histórico ficam bloqueados.

## Compatibilidade entre site e banco

A migração **mantém** a função `entrar()` devolvendo texto, que é o que o site atual da `main` espera, e **acrescenta** a `entrar_v2()`, que devolve JSON e é usada pelo site novo. Por isso a ordem entre migração e merge não quebra o login:

| Site \ Banco | Banco antigo | Banco migrado |
|---|---|---|
| **Site atual (`main`)** | normal | o login funciona; quem está pendente vê o mural **vazio** |
| **Site novo (`fase1-membros`)** | mostra "o banco ainda não foi atualizado" | normal |

A `entrar()` antiga só será removida numa migração futura, quando o site novo estiver no ar há algum tempo.

## Ordem recomendada

### 0. Antes de começar

- [ ] No Clerk, em **User & authentication**, o **Username** está ligado e é **obrigatório**.
- [ ] No Clerk, em **Sessions → Customize session token**, está salvo `{ "username": "{{user.username}}" }`.
- [ ] **Não** coloque o Clerk em modo restrito. Os cadastros continuam abertos e o controle é feito pela aprovação no mural.
- [ ] Saiba o seu **username** exato no Clerk.

### 1. Cópia de segurança (não destrutiva)

No SQL Editor do Supabase. O schema `backup` **não é exposto pela API**: nunca crie backup no `public`, porque o Supabase libera tabelas novas do `public` para a API.

```sql
create schema if not exists backup;
create table backup.usuarios_antes_001 as select * from public.usuarios;
create table backup.codigos_antes_001  as select * from public.codigos;
create table backup.copias_antes_001   as select * from public.copias;
select (select count(*) from backup.usuarios_antes_001) as usuarios,
       (select count(*) from backup.codigos_antes_001)  as codigos,
       (select count(*) from backup.copias_antes_001)   as copias;
```

Anote os três números.

### 2. Aplicar a migração

Cole **todo** o arquivo `migrations/001_membros.sql` no SQL Editor e clique em **Run**. Ele roda numa transação única: se der qualquer erro, nada é aplicado.

Confira a mensagem (NOTICE) no resultado:

- **`PRIMEIRA APLICAÇÃO: N usuário(s) existente(s) ficaram PENDENTES`** é o esperado na primeira vez.
- Se aparecer **`REAPLICAÇÃO`**, a migração já tinha rodado antes; veja "Primeira aplicação x reaplicação" abaixo.

### 3. Verificar (só leitura)

```sql
select versao, primeira_aplicacao, aplicacoes, revertida_em from public.migracoes;
select papel, situacao, count(*) from public.usuarios group by 1, 2 order by 1, 2;
select (select count(*) from public.codigos) as codigos, (select count(*) from public.copias) as copias;
```

Os números de códigos e cópias têm que ser **iguais** aos do passo 1. A matriz completa de permissões está nas seções "MATRIZ" de `tests/04_permissoes.sql`: elas também são só leitura e podem ser coladas aqui.

### 4. Criar o seu registro e virar o primeiro admin

1. Abra o site atual e entre com a sua conta. O mural vai aparecer vazio, o que é o esperado: você está pendente.
2. No SQL Editor:
   ```sql
   select public.definir_primeiro_admin('SEU_USERNAME');
   ```
   Resposta esperada: `SEU_USERNAME agora é administrador`.
   - Se der `usuario_inexistente`, a sua conta ainda não foi registrada. Volte ao item 1 ou confira o username com `select nome from public.usuarios;`.
   - Se der `ja_existe_admin`, a migração já foi aplicada antes; veja a reaplicação abaixo.

### 5. Publicar o site novo

Faça o merge do Pull Request `fase1-membros → main`. O GitHub Pages atualiza em 1 a 2 minutos; depois recarregue com **Ctrl+F5**.

### 6. Liberar o grupo

Abra a aba **Admin**, confira os pedidos e aprove cada pessoa. Elas não precisam fazer nada: a tela "Solicitação enviada" libera o acesso sozinha.

## Primeira aplicação x reaplicação

| Situação | O que a migração faz com os usuários | Admins | Mensagem |
|---|---|---|---|
| **Primeira aplicação** (a coluna `papel` não existia) | todos ficam **pendentes** | nenhum: rode `definir_primeiro_admin` | `PRIMEIRA APLICAÇÃO` + `ATENÇÃO: nenhum admin ativo` |
| **Reaplicação** (rodar a 001 de novo) | **nada muda**: papéis e situações ficam como estão | mantidos | `REAPLICAÇÃO: papéis mantidos — X admin(s)…` |
| **Reaplicação depois do `_down`** | papéis guardados voltam a valer; contas criadas no intervalo ficam pendentes | mantidos | `REAPLICAÇÃO` |
| **Reaplicação depois da LIMPEZA OPCIONAL do `_down`** | conta como primeira aplicação: todos pendentes de novo | nenhum | `PRIMEIRA APLICAÇÃO` |

A tabela `public.migracoes` registra quantas vezes a 001 rodou e se foi revertida. Essa tabela não é acessível pela API.

## Recuperação

Siga na ordem e pare no primeiro item que resolver.

### A. Diagnóstico pela mensagem do site

| O site mostra | Causa provável | O que fazer |
|---|---|---|
| "O site foi atualizado, mas o banco de dados ainda não" | merge feito sem a migração | aplicar o passo 2 |
| "Solicitação enviada" na **sua** conta | você ainda não é admin | passo 4 (`definir_primeiro_admin`) |
| "O login não enviou seu nome de usuário" | session token sem `username`, ou a conta não tem username | conferir o passo 0; a pessoa define o username pelo botão do site |
| "Esse nome de usuário já pertence a outra pessoa" | outro registro do mural tem esse nome | escolher outro username no Clerk |
| "O banco recusou o login" | integração Clerk ↔ Supabase | Supabase → Authentication → Third-party auth → Clerk (domínio certo) |
| "Não foi possível carregar o login (Clerk)" / "a conexão com o banco" | bloqueador de anúncios ou rede | desativar o bloqueador para o site; testar em aba anônima |
| Mural vazio no **site atual**, sem mensagem | migração aplicada e merge ainda não feito | normal; seguir para o passo 5 |

### B. Consultas de diagnóstico (só leitura)

```sql
-- quem é quem
select nome, papel, situacao, atualizado_em from public.usuarios order by papel, nome;
-- últimas ações de acesso
select criado_em, acao, alvo_id, por_id, motivo from public.eventos_acesso order by criado_em desc limit 20;
-- funções que o site usa existem?
select proname from pg_proc where pronamespace = 'public'::regnamespace order by 1;
```

### C. Sem nenhum admin com acesso (ex.: o admin trocou de conta no Clerk)

Só no SQL Editor; o site não consegue chamar essa função:

```sql
select public.recuperacao_promover_admin('USERNAME', 'motivo da recuperação');
```

Ela funciona mesmo que já existam admins, e fica registrada no histórico como `recuperacao_admin` junto com o motivo.

### D. Voltar tudo ao estado anterior

Faça nesta ordem, para o site nunca ficar apontando para funções que deixaram de existir:

1. **Site:** no GitHub, abra o Pull Request já mesclado e clique em **Revert**, depois faça o merge do revert. A `main` volta ao site antigo.
2. **Banco:** cole `migrations/001_membros_down.sql` no SQL Editor e rode. Ele volta as funções, as políticas e as views originais e **não apaga dados**: os papéis e o histórico ficam guardados para uma reaplicação futura.
3. **Conferir:** `select count(*) from public.codigos;` e o mesmo para `copias` têm que bater com o passo 1.

Se, por qualquer motivo, os dados de `usuarios`, `codigos` ou `copias` estiverem diferentes do backup, **não apague nada**: compare com `backup.*_antes_001` antes de qualquer correção.

## Crescimento do grupo

- O mural não tem limite de membros nem de administradores.
- Os limites que existem são os dos planos gratuitos. Confira os valores atuais nos painéis:
  - **Clerk:** a instância de desenvolvimento tem limite de usuários e mostra o selo "Development mode". Para crescer, migre para a instância de produção, que já pode usar o domínio `jaogulozin.com.br`.
  - **Supabase:** 500 MB de banco, e o projeto pausa depois de 7 dias sem uso.

---

# Migração 002 (cópias e ranking)

Aplica `migrations/002_copias_ranking.sql`, que cria a cópia individual com motivo, a cópia em lote transacional, a recuperação de lotes e a estatística "aproveitados". Leva uns 10 minutos.

## O que muda para quem usa

| Ação | Antes | Depois |
|---|---|---|
| Copiar um código | copiava sempre, mesmo sem registrar | o banco decide primeiro: registrado, já copiado ou próprio **copiam**; esgotado, vencido ou apagado **não copiam** e mostram o motivo |
| Copiar lista | `{a b c}`, montada no navegador e registrada uma a uma | **um código por linha**, sem quebra no fim, registrada **numa transação só**; só vem o que foi realmente registrado |
| Cópia automática falhou | lista perdida | caixa com os códigos + "Copiar de novo" + "Meus lotes das últimas 48 h", sem gastar cópias |
| Ranking | postados | postados (mesma ordem) + **Aproveitados** |

As regras não mudam: 48 horas, até 3 pessoas distintas, uma cópia por pessoa, e o autor não conta.

## Compatibilidade entre site e banco

| Site \ Banco | Banco só com a 001 | Banco com a 002 |
|---|---|---|
| **Site atual (`main`)** | normal | normal (`copiar_codigo()` e o ranking antigo continuam funcionando) |
| **Site novo (`fase2-copias-ranking`)** | ao copiar, mostra "o banco ainda não foi atualizado" | normal |

Ordem recomendada: **migração primeiro, merge depois**. Nesse intervalo o site atual continua igual.

## Passo a passo

1. **Snapshot de dados** (é só uma cópia das linhas; não é um backup completo, porque não leva chaves, índices, políticas nem funções):
   ```sql
   create schema if not exists backup;
   create table backup.copias_antes_002 as select * from public.copias;
   select count(*) from backup.copias_antes_002;
   ```
2. **Aplicar:** cole `migrations/002_copias_ranking.sql` inteiro no SQL Editor e clique em **Run**. Ele roda numa transação única.
   - Esperado: `MIGRAÇÃO 002 APLICADA: N cópia(s) existente(s) preservada(s)`.
   - Se aparecer `A migração 001_membros precisa estar aplicada`, nada foi feito: a 001 não está ativa.
   - Se aparecer `MIGRAÇÃO 002 REAPLICADA`, ela já tinha rodado antes. Isso é seguro: funções e ranking são atualizados e nenhuma cópia é alterada.
3. **Verificar (só leitura):**
   ```sql
   select versao, aplicacoes, revertida_em from public.migracoes order by versao;
   select count(*) from public.copias;   -- igual ao snapshot
   select proname from pg_proc where pronamespace = 'public'::regnamespace and proname in
     ('copiar_codigo_v2', 'pegar_lote', 'recuperar_lote', 'meus_lotes', 'resumo_lote');   -- 5 linhas
   ```
   Também rode `tests/verificar_supabase_anon.sh`, que agora inclui as funções novas e deve terminar em "VISITANTE ANÔNIMO NÃO ACESSA NADA".
4. **Merge** do PR `fase2-copias-ranking → main`. Espere 1 a 2 minutos e recarregue com **Ctrl+F5**.
5. **Testes reais** (veja a lista abaixo).

## Testes reais depois do merge

| # | Teste | Esperado |
|---|---|---|
| 1 | Copiar um código de outra pessoa | "copiado e registrado"; o contador do código sobe |
| 2 | Copiar o mesmo código de novo | "copiado de novo… não gastou outra cópia"; o contador não muda |
| 3 | Copiar um código seu | "o código é seu…"; o contador não muda |
| 4 | "Copiar lista" com N = 3 | até 3 códigos, um por linha, os que vencem antes primeiro |
| 5 | Colar no `comprador_cupons.py` | ele lê todos os códigos da lista |
| 6 | "Copiar lista" sem nada disponível | "Não há códigos… Nada foi registrado nem copiado" |
| 7 | "Meus lotes das últimas 48 h" → Recuperar | copia os mesmos códigos; os contadores não mudam |
| 8 | Duas pessoas pedindo lote ao mesmo tempo | nenhum código passa de 3/3; ninguém recebe código repetido |
| 9 | No celular (Safari/iPhone e Chrome/Android) | copia direto ou mostra a caixa de cópia manual |
| 10 | Ranking | coluna "Aproveitados"; a ordem continua por postados |

## Reverter

Faça nesta ordem:

1. **Site:** dê **Revert** no PR da Fase 2 e faça o merge do revert.
2. **Banco:** rode `migrations/002_copias_ranking_down.sql`. Ele remove as funções novas e volta o ranking da 001. **Nenhuma cópia é apagada**; a coluna `copias.lote_id` fica guardada (a limpeza opcional está no fim do arquivo).
3. **Conferir:** `select count(*) from public.copias;` tem que bater com o snapshot.

A 001 só pode ser revertida **depois** da 002: o `001_membros_down.sql` recusa enquanto a 002 estiver ativa.
