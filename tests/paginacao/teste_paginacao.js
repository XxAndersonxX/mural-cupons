// Uso: tests/paginacao/preparar.sh e depois  node tests/paginacao/teste_paginacao.js
// (precisa de playwright com chromium e de @supabase/supabase-js@2.45.4 instalados).
//
// Testes da carga paginada com supabase-js REAL + PostgREST REAL (db-max-rows 1000,
// como o Supabase) + banco local com as migrações 001–003. O Clerk é simulado
// (um stub que devolve um JWT assinado com o segredo do PostgREST local).
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// supabase-js na MESMA versão do index.html: npm install --no-save @supabase/supabase-js@2.45.4
const UMD = path.join(path.dirname(require.resolve('@supabase/supabase-js/package.json')), 'dist/umd');
const SEGREDO = 'segredo-de-teste-local-com-mais-de-32-caracteres';
const API = 'http://127.0.0.1:3999', API200 = 'http://127.0.0.1:3998';
const SITE = 'http://localhost:8771';
const ARQ = process.env.ARQ || 'novo.html', ARQ200 = process.env.ARQ200 || 'novo200.html';

const PSQL = (process.env.PSQL_BASE || 'psql -h 127.0.0.1 -p 5499 -U postgres').split(' ');
const sql = q => execFileSync(PSQL[0], [...PSQL.slice(1), '-d', 'mural_pag', '-q', '-X', '-A', '-t',
  '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' }).trim();
const ativosDB = () => sql('select string_agg(x::text, \',\') from teste.ativos() x').split(',').filter(Boolean).map(Number);
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const jwt = (sub, username) => {
  const h = b64({ alg: 'HS256', typ: 'JWT' }), p = b64({ sub, username, role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 3600 });
  return `${h}.${p}.${crypto.createHmac('sha256', SEGREDO).update(`${h}.${p}`).digest('base64url')}`;
};
const STUB_CLERK = `window.Clerk = {
  isSignedIn: true, load: async () => {}, user: { id: window.__U.id, username: window.__U.username },
  session: { getToken: async () => window.__U.token }, addListener() {}, mountSignIn() {}, unmountSignIn() {},
  mountUserProfile() {}, unmountUserProfile() {}, signOut: async () => {} };`;

let falhas = 0;
const exige = (c, d) => { console.log((c ? 'ok  ' : 'FALHOU ') + d); if (!c) falhas++; };
const iguais = (a, b) => a.length === b.length && a.every((x, i) => x === b[i]);
const dormir = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const navegador = await chromium.launch();

  // abre o site logado como `usuario`; `ctl` permite atrasar/derrubar requisições à API
  async function abrir(arquivo, usuario, ctl = {}) {
    const ctx = await navegador.newContext({ viewport: { width: 1200, height: 900 } });
    await ctx.addInitScript(u => { window.__U = u; }, { id: 'user_' + usuario, username: usuario, token: jwt('user_' + usuario, usuario) });
    await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
    await ctx.route(/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/(.+)$/, r => {
      const f = r.request().url().match(/umd\/([^?]+)/)[1];
      r.fulfill({ status: 200, contentType: 'application/javascript', headers: { 'access-control-allow-origin': '*' }, body: fs.readFileSync(path.join(UMD, f)) });
    });
    await ctx.route(/clerk\.accounts\.dev\/npm\/@clerk\//, r => r.fulfill({ status: 200, contentType: 'application/javascript',
      headers: { 'access-control-allow-origin': '*' }, body: /clerk-js/.test(r.request().url()) ? STUB_CLERK : '' }));
    ctl.log = [];
    await ctx.route(/127\.0\.0\.1:399[89]\//, async r => {
      const u = new URL(r.request().url()); u.pathname = u.pathname.replace(/^\/rest\/v1/, '');   // supabase-js usa /rest/v1 (gateway do Supabase)
      const tabela = u.pathname.slice(1);
      const tipo = u.searchParams.get('order') === 'id.desc' ? 'topo' : (u.searchParams.has('limit') ? 'pagina' : 'outra');
      const ev = { tabela, tipo, url: u.search, inicio: Date.now() };
      ctl.log.push(ev);
      ctl.voo = ctl.voo || {}; ctl.maxVoo = ctl.maxVoo || {};
      ctl.voo[tabela] = (ctl.voo[tabela] || 0) + 1; ctl.maxVoo[tabela] = Math.max(ctl.maxVoo[tabela] || 0, ctl.voo[tabela]);
      try {
        if (ctl.antes) await ctl.antes(ev, ctl.log);
        if (ctl.atraso && tabela === 'codigos_ativos') await dormir(ctl.atraso);
        const f = ctl.falhar && ctl.falhar(ev, ctl.log);
        if (f === 'rede') return await r.abort('failed');
        if (f === '500') return await r.fulfill({ status: 500, contentType: 'application/json', body: '{"code":"XX000","message":"erro interno simulado"}' });
        await r.continue({ url: u.toString() });
      } finally { ctl.voo[tabela]--; }
    });
    const p = await ctx.newPage(); p.erros = [];
    p.on('pageerror', e => p.erros.push(e.message));
    if (process.env.DEBUG) { p.on('console', m => console.log('  console:', m.text().slice(0, 300))); p.on('response', async r => { if (r.status() >= 400) console.log('  http', r.status(), r.url().slice(0, 120), (await r.text().catch(() => '')).slice(0, 200)); }); p.on('requestfailed', r => console.log('  falhou:', r.url().slice(0, 100), r.failure()?.errorText)); }
    await p.goto(`${SITE}/${arquivo}`);
    await p.waitForFunction(() => typeof eu !== 'undefined' && eu && (eu.acesso === false || (codigos.length || document.querySelector('#lista .vazio:not(:empty)'))) && !cargaEmCurso, null, { timeout: Number(process.env.ESPERA || 30000) }).catch(() => {});
    p.ctx = ctx; p.ctl = ctl;
    return p;
  }
  const idsNaPagina = p => p.evaluate(() => codigos.map(c => c.id));
  const atualizarJa = p => p.evaluate(() => atualizar());
  const paginasDe = (log, tabela) => log.filter(e => e.tabela === tabela && e.tipo !== 'outra');

  // ---------- 1. tamanhos ----------
  const SECOES = (process.env.SECOES || '1,2,3,4,5,6').split(',');
  if (SECOES.includes('1')) {
  console.log('== 1. tamanhos (PostgREST com db-max-rows = 1000)');
  for (const n of (process.env.SO ? process.env.SO.split(',').map(Number) : [0, 1, 499, 500, 501, 999, 1000, 1001, 2500])) {
    sql(`select teste.gera(${n})`);
    const esperado = ativosDB();
    const p = await abrir(ARQ, 'pedro');
    p.ctl.log.length = 0;
    await atualizarJa(p);
    const ids = await idsNaPagina(p);
    const ordenados = [...ids].sort((a, b) => a - b);
    const req = paginasDe(p.ctl.log, 'codigos_ativos');
    const esperadoReq = n === 0 ? 1 : 1 + Math.ceil(n / 500);
    exige(ids.length === n && new Set(ids).size === ids.length && iguais(ordenados, esperado),
      `${String(n).padStart(4)} códigos: carregados ${ids.length}, sem duplicados, iguais ao banco; ${req.length} requisições (esperado ${esperadoReq})`
      + (req.length === esperadoReq ? '' : ' <- requisições diferentes'));
    if (req.length !== esperadoReq && ids.length === n) { console.log('FALHOU número de requisições'); falhas++; }
    if (n === 2500) {
      // contadores e filtros por plataforma; os de pedro no fim
      for (const plat of ['777', 'BRA365', 'Sorte25', '77']) {
        const nb = Number(sql(`select count(*) from public.codigos c where c.id in (select teste.ativos()) and plataforma = '${plat}'`));
        await p.click(`[data-plat="${plat}"]`); await p.waitForTimeout(100);
        const qtd = (await p.textContent(`[data-plat="${plat}"] .qtd`)).trim();
        const linhas = await p.$$eval('#lista .bilhete', els => els.map(e => !!e.querySelector('.tag') && e.querySelector('.tag').textContent.trim() === 'seu'));
        const primeiroSeu = linhas.indexOf(true);
        exige(qtd === `${nb} códigos` && linhas.length === nb && primeiroSeu > 0 && linhas.slice(primeiroSeu).every(Boolean),
          `      ${plat}: contador ${qtd}, ${linhas.length} na lista, os ${linhas.length - primeiroSeu} de pedro no fim`);
      }
    }
    exige(p.erros.length === 0, `      sem erros de JS`);
    await p.ctx.close();
  }

  // contraprova: o index.html da main corta em 1000
  sql('select teste.gera(2500)');
  {
    const p = await abrir('main.html', 'pedro');
    await p.waitForFunction(() => codigos.length > 0, null, { timeout: 20000 }); await p.waitForTimeout(500);
    const n = (await idsNaPagina(p)).length;
    exige(n === 1000, `contraprova: a main carrega só ${n} de 2500 (corte silencioso do servidor)`);
    await p.ctx.close();
  }
  // servidor com limite MENOR que a página (200 < 500): não para no "veio menos que o pedido"
  sql('select teste.gera(1001)');
  {
    const p = await abrir(ARQ200, 'pedro');
    await atualizarJa(p);
    const ids = await idsNaPagina(p);
    exige(iguais([...ids].sort((a, b) => a - b), ativosDB()), `servidor limitando a 200 por resposta: carregou os ${ids.length} de 1001 mesmo assim`);
    await p.ctx.close();
  }

  }
  // ---------- 2. alterações durante o carregamento ----------
  if (SECOES.includes('2')) {
  console.log('== 2. publicação, exclusão, expiração e esgotamento DURANTE a leitura');
  sql('select teste.gera(1600)');
  {
    const inicial = ativosDB();
    const lidosNaPag1 = inicial.slice(0, 500), naoLidos = inicial.slice(1100);
    const apagarLido = lidosNaPag1.slice(10, 12), apagarNaoLido = naoLidos.slice(5, 8);
    const expirar = naoLidos.slice(20, 22), esgotar = naoLidos.slice(30, 32);
    let feito = false, novos = [];
    const p = await abrir(ARQ, 'pedro');
    p.ctl.antes = async (ev, log) => {
      if (feito || ev.tabela !== 'codigos_ativos' || ev.tipo !== 'pagina') return;
      if (paginasDe(log, 'codigos_ativos').filter(e => e.tipo === 'pagina').length !== 2) return;
      feito = true;   // segunda página pedida: muda o banco antes de ela ser respondida
      novos = sql(`insert into public.codigos (plataforma, codigo, autor_id) select '777', 'NOVO' || g, 'user_cafe' from generate_series(1, 5) g returning id`).split('\n').map(Number);
      sql(`delete from public.codigos where id in (${[...apagarLido, ...apagarNaoLido].join(',')})`);
      sql(`update public.codigos set criado_em = now() - interval '49 hours' where id in (${expirar.join(',')})`);
      sql(`insert into public.copias (codigo_id, usuario_id) select c, u from unnest(array[${esgotar.join(',')}]) c, unnest(array['user_anderson','user_joao','user_cafe']) u`);
    };
    p.ctl.log.length = 0;
    await atualizarJa(p);
    const ids = await idsNaPagina(p), conj = new Set(ids);
    const sumiramNaoLidos = [...apagarNaoLido, ...expirar, ...esgotar];
    exige(feito, 'banco alterado no meio da leitura (antes da 2ª página)');
    exige(conj.size === ids.length, `nenhum duplicado (${ids.length} recebidos)`);
    exige(novos.every(i => !conj.has(i)), 'publicados durante a leitura: ficam para a próxima atualização (acima do teto)');
    exige(sumiramNaoLidos.every(i => !conj.has(i)), 'apagados/vencidos/esgotados ainda não lidos: não aparecem');
    exige(apagarLido.every(i => conj.has(i)), 'apagados depois de lidos: aparecem nesta carga (como estavam ao ser lidos)');
    const deveriam = inicial.filter(i => !sumiramNaoLidos.includes(i));
    exige(deveriam.every(i => conj.has(i)) && ids.length === deveriam.length, 'nenhum código que continuou ativo foi pulado');
    p.ctl.antes = null;
    await atualizarJa(p);
    exige(iguais([...(await idsNaPagina(p))].sort((a, b) => a - b), ativosDB()), 'a atualização seguinte fica exatamente igual ao banco');
    await p.ctx.close();
  }

  }
  // ---------- 3. falhas no meio ----------
  console.log('== 3. falha na 2ª ou 3ª página');
  for (const [qual, k, modo] of [['codigos_ativos', 2, 'rede'], ['codigos_ativos', 3, 'rede'], ['codigos_ativos', 3, '500'], ['ranking', 2, 'rede']]) {
    sql('select teste.gera(1600)');
    sql(`delete from public.usuarios where id like 'extra_%'`);
    sql(`insert into public.usuarios (id, nome, papel, situacao) select 'extra_' || lpad(g::text, 4, '0'), 'extra' || g, 'membro', 'ativo' from generate_series(1, 1200) g`);
    const p = await abrir(ARQ, 'pedro');
    await atualizarJa(p);
    const antesIds = await idsNaPagina(p), antesUsu = await p.evaluate(() => usuarios.length);
    const antesHtml = await p.innerHTML('#lista');
    sql(`insert into public.codigos (plataforma, codigo, autor_id) select '777', 'DEPOIS' || g, 'user_cafe' from generate_series(1, 10) g`);
    p.ctl.log.length = 0;
    p.ctl.falhar = (ev, log) => ev.tabela === qual && ev.tipo === 'pagina'
      && log.filter(e => e.tabela === qual && e.tipo === 'pagina').length === k ? modo : null;
    await atualizarJa(p);
    const depoisIds = await idsNaPagina(p);
    const faixa = await p.isVisible('#faixaErro'), texto = await p.textContent('#faixaErroTexto');
    const pedidasDepois = p.ctl.log.filter(e => e.tabela === qual && e.tipo === 'pagina').length;
    exige(iguais(depoisIds, antesIds) && await p.evaluate(() => usuarios.length) === antesUsu && await p.innerHTML('#lista') === antesHtml,
      `${qual}, ${k}ª página, ${modo}: dados e tela anteriores preservados (nada parcial)`);
    exige(faixa && /lista completa/.test(texto), `      faixa de erro clara: "${texto.slice(0, 60)}…"`);
    exige(pedidasDepois === k, `      parou na página que falhou (${pedidasDepois} pedidas)`);
    p.ctl.falhar = null;
    await p.click('#btnFaixaTentar'); await p.waitForFunction(() => !cargaEmCurso);
    await atualizarJa(p);
    exige(iguais([...(await idsNaPagina(p))].sort((a, b) => a - b), ativosDB()) && !(await p.isVisible('#faixaErro')),
      `      "Tentar de novo": lista completa (${(await idsNaPagina(p)).length}) e faixa some`);
    await p.ctx.close();
  }

  // ---------- 4. atualizações simultâneas ----------
  console.log('== 4. atualizações simultâneas');
  sql('select teste.gera(1200)');
  {
    const p = await abrir(ARQ, 'pedro');
    await atualizarJa(p);
    p.ctl.atraso = 250; p.ctl.log.length = 0; p.ctl.maxVoo = {};
    const r = await p.evaluate(async () => {
      const t0 = Date.now(), ps = [];
      for (let i = 0; i < 5; i++) ps.push(atualizar());
      await new Promise(r => setTimeout(r, 300));
      for (let i = 0; i < 3; i++) ps.push(atualizar());
      await Promise.all(ps);
      return { ms: Date.now() - t0, mesmas: new Set(ps).size };
    });
    const cargas = p.ctl.log.filter(e => e.tabela === 'codigos_ativos' && e.tipo === 'topo').length;
    exige(cargas === 2, `8 pedidos simultâneos -> ${cargas} cargas (1 + no máximo 1 extra)`);
    exige(p.ctl.maxVoo.codigos_ativos === 1, `nunca duas requisições de códigos ao mesmo tempo (máximo em voo: ${p.ctl.maxVoo.codigos_ativos})`);

    // ação durante uma carga: o pedido da ação vê o dado novo
    const emVoo = p.evaluate(() => atualizar());
    await dormir(100);
    const novo = Number(sql(`insert into public.codigos (plataforma, codigo, autor_id) values ('777', 'NOVO_ACAO', 'user_cafe') returning id`));
    const viu = await p.evaluate(async id => { await atualizar(); return codigos.some(c => c.id === id); }, novo);
    await emVoo;
    exige(viu, 'pedido feito durante uma carga em andamento espera e enxerga o código publicado depois dele (antes era descartado)');

    // pelo próprio site: postar enquanto uma atualização automática está no meio
    const auto = p.evaluate(() => atualizar());
    await dormir(100);
    await p.fill('#inCodigos', 'POSTADOPELOSITE');
    await p.click('#btnPostar');
    await p.waitForFunction(() => codigos.some(c => c.codigo === 'POSTADOPELOSITE'), null, { timeout: 15000 }).then(() => exige(true, 'postar pelo site durante uma carga: o código aparece sem esperar o próximo ciclo'),
      () => exige(false, 'postar pelo site durante uma carga: o código aparece sem esperar o próximo ciclo'));
    await auto;
    exige(p.erros.length === 0, 'sem erros de JS');
    await p.ctx.close();
  }

  // ---------- 5. ranking, usuários e administração com mais de 1000 membros ----------
  console.log('== 5. ranking / usuários / admin com 1200+ membros');
  sql(`delete from public.usuarios where id like 'extra_%'`);
  sql(`insert into public.usuarios (id, nome, papel, situacao) select 'extra_' || lpad(g::text, 4, '0'), 'extra' || g, 'membro', 'ativo' from generate_series(1, 1200) g`);
  sql('select teste.gera(50)');
  {
    const membros = Number(sql(`select count(*) from public.usuarios where papel in ('membro','admin') and situacao = 'ativo'`));
    const todos = Number(sql('select count(*) from public.usuarios'));
    const p = await abrir(ARQ, 'anderson');
    await atualizarJa(p);
    exige(await p.evaluate(() => usuarios.length) === membros, `ranking: ${membros} membros carregados (a main pararia em 1000)`);
    await p.goto(`${SITE}/${ARQ}#ranking`); await p.waitForFunction(() => usuarios.length > 1000 && !cargaEmCurso, null, { timeout: 30000 });
    exige(await p.$$eval('#tbRanking tr', t => t.length) === membros, 'aba Ranking mostra todos');
    exige(await p.$$eval('#tbUsuarios tr', t => t.length) === membros, 'aba Usuários mostra todos');
    const adm = await p.evaluate(() => loja.adminUsuarios());
    const datas = adm.map(u => Date.parse(u.criado_em));
    exige(adm.length === todos && datas.every((d, i) => !i || d >= datas[i - 1]), `admin: ${adm.length} usuários, em ordem de criação`);
    exige(p.erros.length === 0, 'sem erros de JS');
    await p.ctx.close();
  }
  {
    const p = await abrir('main.html', 'anderson');
    await p.waitForFunction(() => usuarios.length > 0, null, { timeout: 20000 }); await p.waitForTimeout(500);
    exige(await p.evaluate(() => usuarios.length) === 1000, 'contraprova: na main o ranking para em 1000');
    await p.ctx.close();
  }
  sql(`delete from public.usuarios where id like 'extra_%'`);

  // ---------- 6. login e permissões ----------
  console.log('== 6. login e permissões');
  sql('select teste.gera(700)');
  for (const [u, esperado] of [['pend', 'pendente'], ['susp', 'suspenso'], ['novato', 'pendente (conta nova)']]) {
    const p = await abrir(ARQ, u);
    await p.waitForTimeout(500);
    const pedidosCodigos = p.ctl.log.filter(e => e.tabela === 'codigos_ativos').length;
    exige(await p.isVisible('#statusAcesso') && (await idsNaPagina(p)).length === 0 && pedidosCodigos === 0,
      `${esperado}: tela de situação, nenhum código pedido nem mostrado`);
    await p.ctx.close();
  }
  {
    // mesmo forçando a leitura, o RLS devolve vazio para quem não é membro
    const p = await abrir(ARQ, 'pend');
    const r = await p.evaluate(async () => { const x = await loja.carregar(); return [x.codigos.length, x.usuarios.length]; });
    exige(r[0] === 0 && r[1] === 0, 'pendente forçando a carga paginada: RLS devolve 0 códigos e 0 no ranking');
    await p.ctx.close();
  }
  {
    const p = await abrir(ARQ, 'cafe');
    await atualizarJa(p);
    exige((await idsNaPagina(p)).length === 700 && !(await p.isVisible('#statusAcesso')), 'membro (cafe): entra e vê os 700');
    await p.ctx.close();
  }
  sql(`delete from public.eventos_acesso where alvo_id = 'user_novato' or por_id = 'user_novato'`);
  sql(`delete from public.usuarios where id = 'user_novato'`);

  await navegador.close();
  console.log(falhas ? `${falhas} FALHA(S)` : 'TODOS OS TESTES DE PAGINAÇÃO PASSARAM');
  process.exit(falhas ? 1 : 0);
})();
