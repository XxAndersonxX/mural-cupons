# Mural de Cupons

Site para um grupo de amigos compartilhar códigos de cupom das plataformas 777, BRA365, Sorte25 e 77.

- Login com **usuário e senha** pelo [Clerk](https://clerk.com)
- Códigos guardados no [Supabase](https://supabase.com)
- Site hospedado de graça no **GitHub Pages**
- Cada código some depois de ser pego por **3 pessoas diferentes** ou **2 dias** depois de postado
- Abas: Plataformas, Usuários, Ranking e Calculadora

Arquivos:

| Arquivo | Para que serve |
|---|---|
| `index.html` | O site inteiro |
| `supabase.sql` | Cria o banco e as regras (rodar 1 vez no Supabase) |
| `README.md` | Este passo a passo |

Abrindo o `index.html` sem configurar nada, o site roda em **modo demonstração**: login só com nome e dados salvos só no seu navegador. Serve para ver como fica.

---

## 1. Supabase (banco de dados)

1. Crie uma conta em <https://supabase.com> e clique em **New project**. Região: **South America (São Paulo)**. Guarde a senha do banco, mas o site não usa ela.
2. Abra **SQL Editor** → **New query**, cole todo o conteúdo de `supabase.sql` e clique em **Run**. Deve aparecer "Success".
3. Vá em **Project Settings → API** (ou **Data API / API Keys**) e copie:
   - **Project URL** (ex.: `https://abcd1234.supabase.co`)
   - a chave **publishable** (ou **anon public**). **Nunca** use a `service_role` / `secret` no site.

## 2. Clerk (login com usuário e senha)

1. Crie uma conta em <https://clerk.com> e crie uma **Application**.
2. Em **Configure → User & authentication**:
   - **Username**: ligado e obrigatório.
   - **Password**: ligado.
   - **Email address**: desligue, ou deixe opcional, se quiser cadastro só com usuário e senha.
   - Desligue os logins sociais (Google etc.) se não quiser.
3. Em **Configure → Sessions → Customize session token**, cole o texto abaixo e salve. Isso põe o nome de usuário no token, para o banco saber quem postou:
   ```json
   { "username": "{{user.username}}" }
   ```
4. Copie a **Publishable key** (começa com `pk_test_`) em **Configure → API keys**.

## 3. Ligar o Clerk ao Supabase

1. No Clerk, abra a configuração da integração com o Supabase (**Integrations → Supabase**, ou pelo guia [Integrate Supabase with Clerk](https://clerk.com/docs/guides/development/integrations/databases/supabase)) e **ative**. Ela mostra um **Clerk domain**: copie.
2. No Supabase, vá em **Authentication → Sign In / Providers → Third-party auth → Add provider → Clerk** e cole esse domínio.

## 4. Configurar o site

Abra o `index.html` num editor (VS Code, Bloco de Notas) e preencha as três linhas no começo:

```js
const CLERK_PUBLISHABLE_KEY = "pk_test_...";
const SUPABASE_URL          = "https://abcd1234.supabase.co";
const SUPABASE_KEY          = "sb_publishable_...";   // ou a chave anon
```

Essas três chaves são **públicas** e podem ficar no código. Quem protege os dados são as regras do `supabase.sql`.

## 5. Publicar grátis no GitHub Pages

1. No GitHub, crie um repositório **público** (ex.: `mural-cupons`).
2. **Add file → Upload files** → envie o `index.html` (o README é opcional) → **Commit**.
3. **Settings → Pages** → em *Source* escolha **Deploy from a branch**, branch **main**, pasta **/(root)** → **Save**.
4. Em 1 a 2 minutos o site fica em `https://SEU-USUARIO.github.io/mural-cupons/`.
5. Mande o link para os amigos. Cada um clica em **Sign up**, escolhe usuário e senha, e pronto.

Para atualizar o site depois, é só enviar o `index.html` novo no mesmo repositório.

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
