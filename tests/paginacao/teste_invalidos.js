// Uso: tests/paginacao/preparar.sh e depois  node tests/paginacao/teste_invalidos.js
// (mesmo ambiente do teste de paginação: supabase-js REAL + PostgREST REAL + banco
// local com as migrações 001–004; Clerk simulado).
//
// Testa no navegador o painel "Reportar inválidos" e a revisão do administrador.
const { chromium } = require('playwright');
const { execFileSync } = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const UMD = path.join(path.dirname(require.resolve('@supabase/supabase-js/package.json')), 'dist/umd');
const SEGREDO = 'segredo-de-teste-local-com-mais-de-32-caracteres';
const SITE = 'http://localhost:8771';
const ARQ = process.env.ARQ || 'novo.html';
const PSQL = (process.env.PSQL_BASE || 'psql -h 127.0.0.1 -p 5499 -U postgres').split(' ');
const sql = q => execFileSync(PSQL[0], [...PSQL.slice(1), '-d', 'mural_pag', '-q', '-X', '-A', '-t',
  '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' }).trim();
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
const dormir = ms => new Promise(r => setTimeout(r, ms));

(async () => {
  const nav = await chromium.launch();
  async function abrir(usuario, ctl = {}, arquivo = ARQ, viewport = { width: 1280, height: 900 }) {
    const ctx = await nav.newContext({ viewport, colorScheme: 'dark' });
    await ctx.addInitScript(u => { window.__U = u; }, { id: 'user_' + usuario, username: usuario, token: jwt('user_' + usuario, usuario) });
    await ctx.grantPermissions(['clipboard-read', 'clipboard-write'], { origin: SITE });
    await ctx.route(/fonts\.(googleapis|gstatic)/, r => r.abort());
    await ctx.route(/cdn\.jsdelivr\.net\/npm\/@supabase\/supabase-js@2\.45\.4\/dist\/umd\/(.+)$/, r => r.fulfill({ status: 200,
      contentType: 'application/javascript', headers: { 'access-control-allow-origin': '*' },
      body: fs.readFileSync(path.join(UMD, r.request().url().match(/umd\/([^?]+)/)[1])) }));
    await ctx.route(/clerk\.accounts\.dev\/npm\/@clerk\//, r => r.fulfill({ status: 200, contentType: 'application/javascript',
      headers: { 'access-control-allow-origin': '*' }, body: /clerk-js/.test(r.request().url()) ? STUB_CLERK : '' }));
    ctl.rpc = [];
    await ctx.route(/127\.0\.0\.1:3999\//, async r => {
      const u = new URL(r.request().url()); u.pathname = u.pathname.replace(/^\/rest\/v1/, '');
      if (u.pathname.startsWith('/rpc/')) ctl.rpc.push(u.pathname.slice(5));
      if (ctl.atrasoRpc && u.pathname === '/rpc/' + ctl.atrasoRpc[0]) await dormir(ctl.atrasoRpc[1]);
      if (ctl.falharRpc && u.pathname === '/rpc/' + ctl.falharRpc) return r.abort('failed');
      await r.continue({ url: u.toString() });
    });
    const p = await ctx.newPage(); p.erros = [];
    p.on('pageerror', e => p.erros.push(e.message));
    await p.goto(`${SITE}/${arquivo}`);
    await p.waitForFunction(() => typeof eu !== 'undefined' && eu && (eu.acesso === false || listaCarregada), null, { timeout: 20000 }).catch(() => {});
    await ocioso(p);
    p.ctx = ctx; p.ctl = ctl; return p;
  }
  const ocioso = p => p.evaluate(async () => {
    const ocupado = () => (typeof cargaEmCurso !== 'undefined' && cargaEmCurso) || (typeof carregando !== 'undefined' && carregando);
    while (ocupado()) await new Promise(r => setTimeout(r, 50));
  });
  const plat = async (p, x) => { await p.click(`[data-plat="${x}"]`); await p.waitForTimeout(80); };
  const id = c => Number(sql(`select max(id) from public.codigos where plataforma = 'BRA365' and codigo = '${c}'`));
  const ativo = c => sql(`select count(*) from public.codigos where plataforma = 'BRA365' and codigo = '${c}' and desativado_em is null`) === '1';

  // cenário: 8 códigos do joao em BRA365; cafe e pedro copiaram X1 e X2
  sql(`delete from public.codigos; delete from public.codigos_bloqueados; delete from public.relatos_invalidos;
    insert into public.codigos (plataforma, codigo, autor_id, criado_em)
      select 'BRA365', 'X' || g, 'user_joao', now() - (10 - g) * interval '10 minutes' from generate_series(1, 8) g;
    insert into public.codigos (plataforma, codigo, autor_id) values ('BRA365', 'DOPEDRO', 'user_pedro');
    insert into public.copias (codigo_id, usuario_id) select c.id, u from public.codigos c, unnest(array['user_cafe', 'user_pedro']) u
      where c.codigo in ('X1', 'X2')`);

  console.log('== 1. painel do membro: entrada, confirmação e resumo');
  const p = await abrir('pedro', {});
  await plat(p, 'BRA365');
  exige(!(await p.isVisible('#inInvalidos')), 'painel começa recolhido (não polui a tela)');
  await p.click('#painelInvalidos summary');
  exige(await p.inputValue('#selPlatInv') === 'BRA365', 'ao abrir, a plataforma vem da aba atual (BRA365)');
  await p.fill('#inInvalidos', 'X1, X2;X2\n  X3\tNAOEXISTE X1 bad!code DOPEDRO');
  await p.click('#btnInvalidos');
  const conf = await p.textContent('#msgInvalidos');
  exige(/6 códigos únicos para BRA365/.test(conf) && /2 repetidos/.test(conf) && /1 com formato inválido/.test(conf)
        && await p.textContent('#btnInvalidos') === 'Enviar 6 para BRA365?' && p.ctl.rpc.filter(x => x === 'relatar_invalidos').length === 0,
        `1º clique só confere, nada enviado: "${conf.slice(0, 95)}…"`);
  await p.fill('#inInvalidos', 'X1, X2;X2\n  X3\tNAOEXISTE X1 bad!code DOPEDRO ');
  exige(await p.textContent('#btnInvalidos') === 'Verificar e enviar', 'mexer na lista cancela a confirmação');
  await p.click('#btnInvalidos');
  p.ctl.atrasoRpc = ['relatar_invalidos', 800];
  await p.click('#btnInvalidos');
  await p.waitForTimeout(150);
  exige(await p.isDisabled('#btnInvalidos') && await p.textContent('#btnInvalidos') === 'Enviando…', 'durante o envio o botão fica bloqueado');
  await p.click('#btnInvalidos', { force: true }).catch(() => {});
  await p.waitForFunction(() => !$('btnInvalidos').disabled, null, { timeout: 10000 });
  p.ctl.atrasoRpc = null;
  const res = await p.textContent('#msgInvalidos');
  exige(p.ctl.rpc.filter(x => x === 'relatar_invalidos').length === 1, 'clique duplo durante o envio: uma requisição só');
  exige(/4 de 6 encontrados no mural \(BRA365\); 3 reportados agora; 1 não encontrado nesta plataforma; 1 é seu \(use Apagar\); 1 com formato inválido\./.test(res)
        && await p.inputValue('#inInvalidos') === '' && await p.textContent('#btnInvalidos') === 'Verificar e enviar',
        `resumo: "${res}"`);
  exige(ativo('X1') && ativo('X2') && ativo('X3'), 'um relato sozinho não tira nada do mural');
  await p.fill('#inInvalidos', 'X1 X2'); await p.click('#btnInvalidos'); await p.click('#btnInvalidos');
  await p.waitForFunction(() => /reportado/.test($('msgInvalidos').textContent) && !$('btnInvalidos').disabled);
  exige(/0 reportados agora; 2 você já tinha reportado/.test(await p.textContent('#msgInvalidos')), 'mesma lista de novo: "você já tinha reportado"');
  // outra plataforma
  await p.selectOption('#selPlatInv', '777'); await p.fill('#inInvalidos', 'X1'); await p.click('#btnInvalidos'); await p.click('#btnInvalidos');
  await p.waitForFunction(() => /encontrado/.test($('msgInvalidos').textContent) && !$('btnInvalidos').disabled);
  exige(/0 de 1 encontrados no mural \(777\); 0 reportados agora; 1 não encontrado/.test(await p.textContent('#msgInvalidos')), 'código de outra plataforma: não encontrado');
  // falha de rede
  p.ctl.falharRpc = 'relatar_invalidos';
  await p.selectOption('#selPlatInv', 'BRA365'); await p.fill('#inInvalidos', 'X4'); await p.click('#btnInvalidos'); await p.click('#btnInvalidos');
  await p.waitForFunction(() => $('msgInvalidos').classList.contains('bad') && !$('btnInvalidos').disabled);
  exige(/conexão|internet/i.test(await p.textContent('#msgInvalidos')) && await p.inputValue('#inInvalidos') === 'X4'
        && sql(`select count(*) from public.relatos_invalidos where codigo = 'X4'`) === '0',
        `falha de rede: mensagem clara, lista mantida para tentar de novo, nada gravado ("${(await p.textContent('#msgInvalidos')).slice(0, 60)}…")`);
  p.ctl.falharRpc = null;
  exige(p.erros.length === 0, 'sem erros de JS');

  console.log('== 2. suspensão automática e cópia de código desativado');
  const velha = await abrir('anderson', {}); await plat(velha, 'BRA365');   // página aberta ANTES da suspensão
  const c = await abrir('cafe', {}); await plat(c, 'BRA365');
  const dispAntes = await c.evaluate(() => Number($('dispQtd').textContent));
  await c.click('#painelInvalidos summary'); await c.fill('#inInvalidos', 'X1\nX3'); await c.click('#btnInvalidos'); await c.click('#btnInvalidos');
  await c.waitForFunction(() => /reportado/.test($('msgInvalidos').textContent) && !$('btnInvalidos').disabled);
  await ocioso(c);
  exige(/1 saiu do mural agora/.test(await c.textContent('#msgInvalidos')) && !ativo('X1') && ativo('X3'),
        'cafe relata X1 (os dois copiaram) e X3 (ninguém copiou): só X1 sai do mural');
  exige(!(await c.evaluate(() => codigos.some(x => x.codigo === 'X1'))), 'a lista de quem relatou já atualiza sem X1');
  exige(await c.evaluate(() => Number($('dispQtd').textContent)) === dispAntes, `contador de disponíveis de cafe não muda (X1 ele já tinha pegado): ${dispAntes}`);
  exige(await velha.evaluate(() => codigos.some(x => x.codigo === 'X1')), 'outra página, ainda com a lista antiga, mostra X1');
  await velha.click(`[data-copiar="${id('X1')}"]`);
  await velha.waitForFunction(() => /desativado/.test($('msgLista').textContent), null, { timeout: 10000 }).catch(() => {});
  exige(/desativado por ter sido relatado como inválido/.test(await velha.textContent('#msgLista'))
        && sql(`select count(*) from public.copias where codigo_id = ${id('X1')} and usuario_id = 'user_anderson'`) === '0',
        'copiar X1 pela lista antiga: "desativado…", nenhuma cópia registrada');
  await ocioso(velha);
  exige(!(await velha.evaluate(() => codigos.some(x => x.codigo === 'X1'))), 'e a lista antiga se atualiza sozinha');
  await velha.fill('#inQtdLote', '20'); await velha.click('#btnLote');
  await velha.waitForFunction(() => /registrad/i.test($('msgLote').textContent), null, { timeout: 10000 }).catch(() => {});
  const lote = await velha.inputValue('#saidaLote');
  exige(!lote.split('\n').includes('X1') && lote.split('\n').length === 8, `lote não traz X1: ${lote.replace(/\n/g, ',')}`);
  for (const x of [c]) await x.ctx.close();

  console.log('== 3. administração: revisar, confirmar e reverter');
  await velha.click('[data-view="admin"], a[href="#admin"]').catch(() => velha.goto(`${SITE}/${ARQ}#admin`));
  await velha.waitForFunction(() => document.querySelectorAll('#tbReportados tr').length > 0 && !/Nenhum/.test($('tbReportados').textContent), null, { timeout: 10000 }).catch(() => {});
  await ocioso(velha); await velha.evaluate(() => atualizarReportados());
  const linhas = await velha.$$eval('#tbReportados tr', trs => trs.map(t => [...t.cells].map(c => c.textContent.replace(/\s+/g, ' ').trim()).join(' | ')));
  exige(linhas.some(l => /^X1\s?BRA365.*\| joao \| 2 \(2 qualif\.\) \| Suspenso por relatos/.test(l))
        && linhas.some(l => /^X3\s?BRA365.*\| joao \| 2 \(0 qualif\.\) \| Ativo/.test(l))
        && linhas.some(l => /^X2\s?BRA365 · .* · 3\/3 \| joao \| 1 \(1 qualif\.\) \| Esgotado/.test(l)),
        `admin vê X1 suspenso (2 qualificados), X3 ativo (2 sem cópia) e X2 esgotado pelo lote (1 relato)`);
  if (process.env.DEBUG) console.log('    linhas:', linhas);
  const bConf = `#tbReportados [data-inv="confirmar"][data-cod-inv="X3"]`;
  await velha.click(bConf);
  exige(await velha.textContent(bConf) === 'Confirmar inválido?' && ativo('X3'), '1º clique em Confirmar só pede confirmação');
  await velha.click(bConf);
  await velha.waitForFunction(() => /confirmado como inválido/.test($('msgReportados').textContent), null, { timeout: 10000 }).catch(() => {});
  await ocioso(velha);
  exige(!ativo('X3') && /X3/.test(await velha.textContent('#tbBloqueados')), 'confirmado: X3 desativado e na lista de bloqueados');
  // republicar o bloqueado
  const pe = await abrir('pedro', {}); await plat(pe, 'BRA365');
  await pe.fill('#inCodigos', 'X3 NOVO1'); await pe.click('#btnPostar');
  await pe.waitForFunction(() => /postado/.test($('msgPostar').textContent), null, { timeout: 10000 }).catch(() => {});
  exige(/1 código postado em BRA365\. .*1 não entrou: confirmado como inválido \(X3\)/.test(await pe.textContent('#msgPostar')),
        `republicar código confirmado: "${await pe.textContent('#msgPostar')}"`);
  // reverter
  const bRev = `#tbBloqueados [data-inv="reverter"][data-cod-inv="X3"]`;
  await velha.click(bRev); await velha.click(bRev);
  await velha.waitForFunction(() => /revertido/.test($('msgReportados').textContent), null, { timeout: 10000 }).catch(() => {});
  await ocioso(velha);
  exige(ativo('X3') && !/X3/.test(await velha.textContent('#tbBloqueados')) && await velha.evaluate(() => codigos.some(x => x.codigo === 'X3')),
        'reverter: X3 volta ao mural, sai dos bloqueados e aparece na lista');
  exige(velha.erros.length === 0 && pe.erros.length === 0, 'sem erros de JS');
  await pe.ctx.close();

  console.log('== 4. acesso e layout');
  for (const u of ['pend', 'susp']) {
    const x = await abrir(u, {}); await x.waitForTimeout(300);
    const coberto = await x.evaluate(() => { const r = $('painelInvalidos').getBoundingClientRect(), t = $('telaLogin');
      const topo = document.elementFromPoint(r.left + 5, r.top + 5); return !t.hidden && t.contains(topo); });
    exige(await x.isVisible('#statusAcesso') && coberto && x.ctl.rpc.filter(r => r === 'relatar_invalidos').length === 0,
          `${u}: fica na tela de situação, que cobre o mural; nenhum relato enviado (o banco também recusa)`);
    await x.ctx.close();
  }
  const cafe = await abrir('cafe', {});
  exige(!(await cafe.isVisible('#painelReportados')), 'membro comum não vê a revisão do admin');
  await cafe.ctx.close();
  for (const [nome, vp] of [['celular', { width: 390, height: 844 }], ['desktop', { width: 1280, height: 900 }]]) {
    const x = await abrir('pedro', {}, ARQ, vp); await plat(x, 'BRA365');
    await x.click('#painelInvalidos summary'); await x.fill('#inInvalidos', 'X5 X6'); await x.click('#btnInvalidos');
    const rol = await x.evaluate(() => document.documentElement.scrollWidth > innerWidth);
    exige(!rol, `${nome}: painel aberto sem rolagem horizontal`);
    await (await x.$('#painelInvalidos')).scrollIntoViewIfNeeded();
    await x.screenshot({ path: path.join(process.env.FOTOS || '/tmp', `invalidos_${nome}.png`) });
    await x.ctx.close();
  }
  await velha.setViewportSize({ width: 390, height: 844 });
  await (await velha.$('#painelReportados')).scrollIntoViewIfNeeded();
  exige(!(await velha.evaluate(() => document.documentElement.scrollWidth > innerWidth)), 'celular: tabela do admin rola dentro do painel');
  await velha.screenshot({ path: path.join(process.env.FOTOS || '/tmp', 'invalidos_admin_celular.png') });
  await velha.ctx.close();

  // contraprova da ordem de implantação: o site ANTIGO com o banco novo
  if (fs.existsSync(path.join(process.env.WEB || '/tmp/mural_paginacao/web', 'main.html'))) {
    console.log('== 5. ordem de implantação (site antigo + banco com a 004)');
    sql(`insert into public.codigos (plataforma, codigo, autor_id) values ('BRA365', 'VELHO1', 'user_joao')`);
    const antigo = await abrir('pedro', {}, 'main.html'); await plat(antigo, 'BRA365');
    sql(`update public.codigos set desativado_em = now(), desativacao = 'admin' where codigo = 'VELHO1'`);
    await antigo.click(`[data-copiar="${id('VELHO1')}"]`); await antigo.waitForTimeout(1500);
    console.log(`    site antigo ao copiar um desativado: ${antigo.erros.length ? 'ERRO DE JS — ' + antigo.erros[0].slice(0, 70) : 'sem erro'}`);
    console.log('    (por isso: publicar o site ANTES de aplicar a 004)');
    await antigo.ctx.close();
  }

  await nav.close();
  console.log(falhas ? `${falhas} FALHA(S)` : 'TODOS OS TESTES DO PAINEL DE INVÁLIDOS PASSARAM');
  process.exit(falhas ? 1 : 0);
})();
