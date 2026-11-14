# Mural de Cupons

Site para um grupo de amigos compartilhar códigos de cupom das plataformas


- Login com **usuário e senha** pelo [Clerk](https://clerk.com)
- Códigos guardados no [Supabase](https://supabase.com)
- Site hospedado de graça no **GitHub Pages**
- Cada código some depois de ser pego por **3 pessoas diferentes** ou **2 dias** depois de postado
- Abas: Plataformas, Usuários, Ranking, Calculadora e Admin
- **Copiar lista:** registra até 200 códigos numa operação só, divididos igualmente entre quem postou (sempre os mais antigos de cada pessoa primeiro), e copia um por linha (pronto para o `comprador_cupons.py`); dá para recuperar os lotes das últimas 48 h sem gastar cópias
- **Reportar inválidos:** cola a lista de rejeitados do comprador; um código só sai do mural com 2 relatos de quem copiou aquela publicação nas últimas 72 h (suspensão) ou com a confirmação de um administrador (que também impede republicar). Nada é apagado; o admin desbloqueia a republicação e reativa publicações separadamente, tudo auditado
- **Ranking** por códigos postados, com a coluna "Aproveitados" (publicações que outro membro pegou)
- **Acesso por aprovação:** qualquer pessoa pode criar conta e pedir para entrar, mas só vê os cupons depois que um administrador aprovar

Arquivos:

| Arquivo | Para que serve |
|---|---|
| `index.html` | O site inteiro |
| `supabase.sql` | Cria o banco e as regras  |
| `migrations/` | Mudanças do banco, em ordem (`001_membros.sql`…), cada uma com seu `_down.sql` para reverter |
| `docs/IMPLANTACAO.md` | **Como aplicar uma migração**: ordem, verificação, primeira aplicação x reaplicação e recuperação |
| `tests/` | Testes de segurança, permissões (SQL e API), concorrência e reversão — rodam num Postgres local, nunca no Supabase |
| `tests/verificar_supabase_anon.sh` | Verificação **só de leitura** no Supabase real: visitante anônimo não acessa nada |
| `README.md` | Este passo a passo |

Com as **três chaves vazias** no `index.html`, o site roda em **modo demonstração**: login só com nome e dados só no seu navegador. Com as chaves preenchidas, ele **nunca** cai no modo demonstração: se o Clerk ou o Supabase não carregarem, aparece uma mensagem de erro.

---

## Custos e limites (tudo gratuito)

| Serviço | Plano grátis | Observação |
|---|---|---|
| GitHub Pages | Ilimitado para sites pequenos | Repositório precisa ser público. As chaves do site são públicas por natureza, então tudo bem. |
| Supabase | 500 MB de banco | **O projeto pausa depois de 7 dias sem nenhum acesso.** Se pausar, entre no painel do Supabase e clique em *Restore*; os dados continuam lá. Com o grupo usando toda semana, não pausa. |
| Clerk | Milhares de usuários por mês | Use a instância de **desenvolvimento** (chave `pk_test_`). Ela funciona no endereço do GitHub Pages e mostra um selo "Development mode" na tela de login. A de produção exige um domínio próprio. |

## Regras que o banco garante

Essas regras rodam no servidor, então não dá para burlar pelo navegador:

- Só quem está logado vê ou posta códigos.
- Um código ativo não pode ser postado de novo na mesma plataforma.
- Cada pessoa pega cada código uma vez só, e não conta pegar o próprio código.
- Na 3ª pessoa diferente, o código some.
- 48 h depois de postado, o código some e pode ser postado de novo.
- Só o autor apaga o próprio código, e só se ninguém pegou ainda.
- Ninguém escreve direto nas tabelas; tudo passa pelas funções do `supabase.sql`.

## Mudar plataformas

Para adicionar ou trocar plataformas, altere a lista nos **dois** lugares:

- `index.html`: `const PLATAFORMAS = [...]`
- `supabase.sql`: `check (plataforma in (...))`. Para um banco que já existe, rode no SQL Editor:
  ```sql
  alter table public.codigos drop constraint codigos_plataforma_check;
  alter table public.codigos add constraint codigos_plataforma_check
    check (plataforma in ('777','BRA365','Sorte25','77','NOVA'));
  ```

## Membros e administradores

| Papel | O que pode |
|---|---|
| **pendente** | Criou conta e pediu acesso. Não vê cupons, ranking nem usuários. |
| **membro** | Usa o mural: vê, posta e pega cupons. |
| **admin** | Tudo de membro + aprova, recusa, suspende, reativa e promove/remove administradores (aba **Admin**). |

- Qualquer pessoa pode se cadastrar pelo Clerk; o cadastro vira um **pedido de acesso** que aparece na aba Admin.
- Um membro ou admin pode ser **suspenso** (perde o acesso na hora) e **reativado** depois.
- Ninguém altera o próprio acesso, e o mural nunca fica sem pelo menos um admin ativo.
- Se dois admins mexerem no mesmo usuário ao mesmo tempo, a segunda ação é recusada e a lista é atualizada.
- Toda ação de admin fica no **Histórico** com quem fez, quando e o motivo.

**Primeiro administrador (uma vez só):** depois de rodar a migração 001, entre no site com a sua conta e rode no SQL Editor `select public.definir_primeiro_admin('SEU_USERNAME');`. Essa função só funciona enquanto não existir nenhum admin e não pode ser chamada pelo site. Os próximos admins são promovidos pela própria aba Admin. Passo a passo completo e recuperação em **[docs/IMPLANTACAO.md](docs/IMPLANTACAO.md)**.

## Testes (para quem mexer no banco)

Num Postgres local descartável (nunca no Supabase):

```bash
PSQL_BASE="psql -h 127.0.0.1 -p 5432 -U postgres" tests/rodar_local.sh
# com testes pela API (precisa do binário do PostgREST):
PSQL_BASE="psql -h 127.0.0.1 -p 5432 -U postgres" PG_HOST=127.0.0.1 PG_PORT=5432 POSTGREST=/caminho/postgrest tests/rodar_local.sh
```

Roda o banco original com dados, aplica a migração (primeira vez), testes de segurança, permissões e concorrência, reaplica, reverte, reaplica de novo e, opcionalmente, testa tudo pela API. Qualquer erro interrompe a bateria; a mensagem `BATERIA COMPLETA OK` só aparece se todas as etapas passarem.

Carga paginada do site (navegador real + supabase-js + PostgREST com limite de 1000 linhas; Postgres local na porta 5499 e Clerk simulado):

```bash
npm install --no-save @supabase/supabase-js@2.45.4   # mesma versão do index.html; precisa também do playwright
POSTGREST=/caminho/postgrest tests/paginacao/preparar.sh
node tests/paginacao/teste_paginacao.js
node tests/paginacao/teste_invalidos.js        # painel "Reportar inválidos" e revisão do admin
```
