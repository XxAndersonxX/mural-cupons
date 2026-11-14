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
2. **Aplicar:** cole `migrations/002_copias_ranking.sql` inteiro no SQL Editor e clique em **Run**.
   - A 002 **não depende** de o editor manter uma transação ou sessão entre os comandos. Ela não usa tabela temporária, todo comando pode ser repetido sem efeito duplicado, e o resultado (primeira aplicação ou reaplicação) é lido de `public.migracoes`. Isso foi testado executando cada um dos 20 comandos numa conexão separada (`tests/08_editor_separado.sh`).
   - **Se aparecer um erro no meio:** anote a mensagem, corrija a causa se houver e **rode o arquivo inteiro de novo**. Os comandos que já tinham passado são refeitos sem efeito duplicado, e a mensagem final só aparece quando tudo terminou.
   - Esperado: `MIGRAÇÃO 002 APLICADA: N cópia(s) existente(s) preservada(s)`.
   - Se aparecer `A migração 001_membros precisa estar aplicada`, nada foi feito: a 001 não está ativa.
   - Se aparecer `MIGRAÇÃO 002 REAPLICADA (execução nº N)`, ela já tinha rodado antes. Isso é seguro: funções e ranking são atualizados e nenhuma cópia é alterada.
   - Se a mensagem final não aparecer, a execução não chegou ao fim: rode o arquivo inteiro de novo.
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

## Observação sobre a 001 no SQL Editor

A `001_membros.sql` (já aplicada em produção) ainda usa uma tabela temporária (`_m001`) **só na mensagem final**. Quando o editor executa comando a comando, todos os comandos anteriores são aplicados normalmente e apenas essa mensagem falha com `relation "_m001" does not exist`. O registro em `public.migracoes` é gravado **antes** dela, então o banco fica correto. Para conferir depois de uma reaplicação da 001, use as consultas do passo 3 da 001 em vez da mensagem.

# Migração 003 (distribuição híbrida do lote)

Aplica `migrations/003_distribuicao_hibrida.sql`. Ela troca **só o critério de escolha** da `pegar_lote()`: mesmo nome, mesmos parâmetros, mesmo formato de resposta e mesmas permissões. Não cria nem altera tabelas, colunas, views ou dados. Leva uns 5 minutos.

## O que muda para quem usa

| | Antes (002) | Depois (003) |
|---|---|---|
| Quais códigos o lote leva | os N que vencem antes, de quem quer que seja | **divididos igualmente entre quem postou**; quem tem menos que a sua parte entrega tudo e a sobra vai para os outros |
| Sobra que não divide igual | — | vai para quem tem o **próximo código mais antigo** (empate exato: menor id) |
| Dentro de cada pessoa | do mais antigo para o mais novo | igual (obrigatório: nunca um mais novo enquanto houver um mais antigo dela disponível) |
| Ordem do texto copiado | vencimento | **igual**: do que vence antes para o que vence depois, sem agrupar por autor |
| Dois lotes na mesma plataforma ao mesmo tempo | o segundo pulava códigos ocupados e podia vir menor | o segundo **espera** o primeiro (milissegundos) e recebe o que sobrou de verdade |
| Espera maior que 5 s (muito raro) | — | "Muita gente pegando códigos desta plataforma agora. Nada foi registrado: tente de novo" |

O equilíbrio é **por pedido**: não há compensação entre lotes diferentes. As regras não mudam: 48 horas, até 3 pessoas distintas, uma cópia por pessoa, autor não conta, máximo de 200, só volta o que foi registrado, recuperação e ranking iguais.

Exemplos (N = 60): 10/10/70/10 → **10/10/30/10**; 10/10/60/20 → **10/10/20/20**; 5/20/60/25 → **5 + 18/18/18 + 1** para quem tem o 19º código mais antigo entre Café, Panda e João.

## Compatibilidade entre site e banco

| Site \ Banco | Banco com a 002 | Banco com a 003 |
|---|---|---|
| **Site atual (`main`)** | normal | normal; no caso raro de espera > 5 s, mostra um erro genérico em vez da mensagem "tente de novo" |
| **Site novo (`fase3-distribuicao-hibrida`)** | normal (critério antigo; só o texto de ajuda já descreve o novo) | normal |

Qualquer ordem funciona. Recomendado: **migração primeiro, merge logo depois**.

## Passo a passo

1. **Snapshot de dados** (só uma cópia das linhas; não é backup completo):
   ```sql
   create schema if not exists backup;
   create table backup.copias_antes_003 as select * from public.copias;
   select count(*) from backup.copias_antes_003;
   ```
2. **Aplicar:** cole `migrations/003_distribuicao_hibrida.sql` inteiro no SQL Editor e clique em **Run**.
   - Como a 002, ela não depende de o editor manter transação ou sessão entre comandos: sem tabela temporária, todo comando pode ser repetido, e primeira aplicação x reaplicação vêm de `public.migracoes`. Testado executando cada um dos 8 comandos numa conexão separada, e interrompendo a execução em cada ponto possível antes de completar de novo (`tests/08_editor_separado.sh`). Em nenhum ponto a `pegar_lote()` fica sem permissão para os membros.
   - Esperado: `MIGRAÇÃO 003 APLICADA: pegar_lote() com distribuição híbrida; nenhum dado alterado.`
   - `A migração 002_copias_ranking precisa estar aplicada antes da 003`: nada foi feito.
   - `MIGRAÇÃO 003 REAPLICADA (execução nº N)`: já tinha rodado; seguro.
   - Erro no meio ou sem mensagem final: corrija a causa, se houver, e **rode o arquivo inteiro de novo**.
3. **Verificar (só leitura):**
   ```sql
   select versao, aplicacoes, revertida_em from public.migracoes order by versao;
   select array_to_string(proconfig, ',') from pg_proc where proname = 'pegar_lote';
     -- search_path="",lock_timeout=5s
   select count(*) from public.copias;   -- igual ao snapshot
   ```
   E `tests/verificar_supabase_anon.sh` deve terminar em "VISITANTE ANÔNIMO NÃO ACESSA NADA".
4. **Merge** do PR `fase3-distribuicao-hibrida → main`. Espere 1 a 2 minutos e recarregue com **Ctrl+F5**.
5. **Testes reais** (abaixo).

## Testes reais depois do merge

| # | Teste | Esperado |
|---|---|---|
| 1 | Com códigos de 3+ pessoas na plataforma, "Copiar lista" com N pequeno (ex.: 3) | 1 código de cada pessoa (as 3 com código mais antigo) |
| 2 | Uma pessoa com muitos códigos e outras com poucos | os poucos vêm todos; o resto sai da que tem muitos |
| 3 | Dentro de cada pessoa | os mais antigos dela; nunca um mais novo no lugar de um mais antigo disponível |
| 4 | Ordem do texto colado | do que vence antes para o que vence depois |
| 5 | Duas pessoas pedindo lote ao mesmo tempo | ninguém recebe repetido, nenhum código passa de 3/3, nenhum dos dois fica menor sem necessidade |
| 6 | Recuperar um lote ("Meus lotes") | mesma lista; contadores não mudam |
| 7 | Cópia individual, ranking, administração | iguais a antes |

## Reverter

1. **Site (opcional):** o site da Fase 3 funciona com a 002; se quiser, dê **Revert** no PR.
2. **Banco:** rode `migrations/003_distribuicao_hibrida_down.sql`. Ele recoloca a `pegar_lote()` da 002 (com `SKIP LOCKED`). **Nenhum dado é alterado**; lotes feitos com a 003 continuam recuperáveis. Pode ser rodado de novo sem efeito.
3. **Conferir:** `select count(*) from public.copias;` bate com o snapshot.

Proteções:

- `002_copias_ranking_down.sql` **recusa** enquanto a 003 estiver ativa (reverta a 003 antes).
- Reaplicar `002_copias_ranking.sql` com a 003 ativa também é **recusado**, porque desfaria a distribuição híbrida sem avisar. Para reaplicar a 002, primeiro reverta a 003, depois reaplique a 002 e então a 003.

Esses dois arquivos da 002 ganharam só essa verificação no começo; para quem não tem a 003, eles se comportam exatamente como antes.

# Migração 004 (relatos de códigos inválidos)

Aplica `migrations/004_codigos_invalidos.sql`. Ela é **aditiva**: não apaga nem altera códigos, cópias ou lotes que já existem.

## Regra (conservadora)

- **Relato:** fica ligado ao ID de quem relatou e vale uma vez por pessoa para cada publicação. Ele aponta para a publicação mais recente daquele código na plataforma escolhida. O autor não relata o próprio código.
- **Relato qualificado:** é o de quem copiou aquela publicação pelo mural. Relatos de quem não copiou ficam registrados para o admin, mas não têm efeito automático.
- **Por que exigir isso:** o comprador marca como "rejeitado" também o cupom que *aquela conta* já usou, o que não prova que ele seja inválido para todos.
- **2 relatos qualificados de pessoas diferentes:** o código é **suspenso**. Sai da lista, do lote e das cópias. Não bloqueia republicar depois de 48 h.
- **Admin confirma:** o código é desativado em todas as publicações daquela plataforma e fica **bloqueado** para republicação, mesmo depois de 48 h.
- **Admin reverte:** desbloqueia, reativa e descarta os relatos antigos, para que não haja nova suspensão imediata.
- **Desativação lógica:** nada é apagado. Cópias, lotes, a recuperação de lotes e o ranking histórico (postados e aproveitados) ficam iguais. A coluna "ativos" do ranking deixa de contar os desativados.

## O que muda no banco

| Objeto | Mudança |
|---|---|
| `codigos` | colunas novas `desativado_em` e `desativacao` (`relatos`/`admin`), nulas para tudo que já existe |
| `relatos_invalidos`, `codigos_bloqueados`, `eventos_invalidos` | tabelas novas; RLS ligado e **nenhum acesso direto** pela API |
| `codigos_ativos` (view) | ignora desativados |
| `copiar_codigo`, `copiar_codigo_v2` | recusam desativados (`false` / status novo `invalidado`) |
| `pegar_lote` | uma condição a mais (ignora desativados); critério e travas da 003 iguais |
| `postar_codigos` | recusa combinações bloqueadas e devolve a lista nova `bloqueados` |
| `relatar_invalidos`, `admin_codigos_invalidos`, `admin_confirmar_invalido`, `admin_reverter_invalido` | funções novas |
| 001, 002, 003 e `003_..._down` | só uma verificação no começo: recusam rodar enquanto a 004 estiver ativa (sobrescreveriam os filtros). Para quem não tem a 004, nada muda |

## Ordem de implantação: **site primeiro, migração depois**

| Site \ Banco | Banco sem a 004 | Banco com a 004 |
|---|---|---|
| **Site atual (`main`)** | normal | ⚠ ao copiar um código desativado por uma lista desatualizada, o site antigo dá erro de JavaScript (não conhece o status `invalidado`); lista, lote e contador funcionam |
| **Site novo** | normal; "Reportar inválidos" e a revisão do admin mostram "o banco ainda não foi atualizado" | normal |

1. Merge do PR `feature/reportar-invalidos → main`. Espere 1 a 2 minutos e recarregue com **Ctrl+F5**.
2. Só então aplique a migração (abaixo).

## Passo a passo da migração

1. **Snapshot de dados** (é uma cópia das linhas, não um backup completo):
   ```sql
   create schema if not exists backup;
   create table backup.codigos_antes_004 as select * from public.codigos;
   create table backup.copias_antes_004 as select * from public.copias;
   ```
2. **Aplicar:** cole `migrations/004_codigos_invalidos.sql` inteiro no SQL Editor e clique em **Run**.
   - Testado também com cada um dos 31 comandos numa conexão separada, e interrompido em cada ponto possível antes de completar de novo. Em nenhum ponto cópias, lote, publicação ou lista ficam sem permissão.
   - Esperado: `MIGRAÇÃO 004 APLICADA: relatos de inválidos e desativação lógica; nenhum código, cópia ou lote alterado.`
   - `A migração 003_distribuicao_hibrida precisa estar aplicada antes da 004`: nada foi feito.
   - `MIGRAÇÃO 004 REAPLICADA (execução nº N)`: já tinha rodado; seguro (relatos, bloqueios e desativações são mantidos).
   - Erro no meio ou sem mensagem final: rode o arquivo inteiro de novo.
3. **Verificar (só leitura):**
   ```sql
   select versao, aplicacoes, revertida_em from public.migracoes order by versao;
   select count(*) as codigos, count(desativado_em) as desativados from public.codigos;   -- desativados = 0
   select (select count(*) from public.copias) = (select count(*) from backup.copias_antes_004) as copias_iguais;
   ```
   E `tests/verificar_supabase_anon.sh` deve terminar em "VISITANTE ANÔNIMO NÃO ACESSA NADA".

## Testes reais depois da migração

| # | Teste | Esperado |
|---|---|---|
| 1 | Membro abre "Reportar inválidos", cola uma lista com repetidos e separadores misturados | 1º clique mostra quantos únicos e a plataforma; 2º envia; resumo com encontrados/reportados/não encontrados |
| 2 | Mesma lista de novo | "você já tinha reportado" |
| 3 | Duas pessoas que **copiaram** o mesmo código relatam | ele sai da lista; quem tentar copiar por uma lista antiga recebe "desativado…" |
| 4 | Três pessoas que **não** copiaram relatam | nada muda; o admin vê os relatos |
| 5 | Admin → "Códigos reportados" → Confirmar (2 cliques) | some do mural e aparece em "Bloqueados"; tentar postar de novo: "não entrou: confirmado como inválido" |
| 6 | Admin → Reverter / Desbloquear | volta ao mural (se ainda estiver dentro das 48 h e com vaga) |
| 7 | Cópias, lote, recuperação, ranking e contador | como antes |

## Reverter

1. **Banco:** rode `migrations/004_codigos_invalidos_down.sql`. A view e as quatro funções voltam a ser **idênticas** às da 003 (o teste compara o texto), e as funções novas são removidas.
   - **Nada é apagado:** relatos, bloqueios, eventos e colunas ficam guardados, e reaplicar a 004 depois restaura o efeito.
   - Enquanto ela estiver revertida, os códigos desativados **voltam a aparecer** e os bloqueados podem ser republicados.
   - Pode ser rodado de novo sem efeito.
2. **Site (opcional):** o site novo funciona sem a 004; só os painéis novos mostram o aviso de banco desatualizado.
