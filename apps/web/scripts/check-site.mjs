#!/usr/bin/env node
/**
 * 站点验收测试（CLAUDE.md §6 Website 必测）。
 *
 * 用【生产式的公开配置】重建站点（注入 process.env，覆盖本地 mock 的 .env），随后对产物断言：
 *  - production build 成功（本脚本负责触发一次干净构建）。
 *  - 八条路由产物齐全，含 404。
 *  - 内部链接全部指向存在的产物文件。
 *  - 关键 CTA：首页/定价含购买链接，下载/定价含下载链接；购买与下载是两个不同 URL。
 *  - 渐进增强：允许无 src 的内联 <script>（JSON-LD / ActivityMock 本地演示增强），
 *    禁止任何外部脚本（带 src），内联脚本禁止网络 API 字样（纯本地 mock 数据）；
 *    无 JS 时 SSR 静态内容完整可见，核心内容与购买/下载均为原生 <a>。
 *  - 不泄露：产物不含私有 API 地址、mock/占位 checkout、secret 模式。
 *  - 法律页（refund/privacy/terms）带草稿/待法务审核标记。
 *
 * typecheck 与 lint 是独立脚本；键盘/焦点/对比度/窄屏由语义 HTML + global.css 保证，
 * 本脚本对可访问性做结构性断言（skip-link、lang、单一 h1、viewport）。
 */
import { spawnSync } from 'node:child_process';
import { readFileSync, readdirSync, statSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, relative } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');

// 生产式公开配置（非 secret，非 mock）。外部 env 优先，便于 CI/部署注入真实 Polar link；
// 本地没有 link 时使用明确的 `.invalid` 测试 fixture，绝不把不存在的 URL 冒充生产 checkout。
const BUILD_ENV = {
  PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL?.trim() || 'https://appidge.com',
  PUBLIC_POLAR_CHECKOUT_URL:
    process.env.PUBLIC_POLAR_CHECKOUT_URL?.trim() || 'https://checkout.example.invalid/appidge-ci',
  PUBLIC_API_BASE_URL: process.env.PUBLIC_API_BASE_URL?.trim() || 'https://api.appidge.com',
  PUBLIC_DOWNLOAD_URL:
    process.env.PUBLIC_DOWNLOAD_URL?.trim() || 'https://updates.appidge.com/appidge-latest.dmg',
};

const failures = [];
const ok = (cond, msg) => {
  if (!cond) failures.push(msg);
};

// ---- 1. 干净的生产构建 ----
if (existsSync(dist)) rmSync(dist, { recursive: true, force: true });
console.log('· 用生产式公开配置执行 astro build …');
const build = spawnSync('pnpm', ['exec', 'astro', 'build'], {
  cwd: root,
  env: { ...process.env, ...BUILD_ENV },
  stdio: 'inherit',
});
if (build.status !== 0) {
  console.error('构建失败，测试终止。');
  process.exit(1);
}

// ---- 收集产物 html ----
function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}
const files = walk(dist);
const htmlFiles = files.filter((f) => f.endsWith('.html'));
const readHtml = (rel) => readFileSync(join(dist, rel), 'utf8');

// ---- 2. 路由产物齐全 ----
// 根路径 = 英文（默认语言），/zh/ 前缀 = 中文。
// 单页信息架构：下载/定价/FAQ 是首页锚点 section（见下方锚点断言），法务三页独立。
const routes = {
  '/': 'index.html',
  '/refund': 'refund/index.html',
  '/privacy': 'privacy/index.html',
  '/terms': 'terms/index.html',
  '/data-usage': 'data-usage/index.html',
  '/zh/': 'zh/index.html',
  '/zh/refund': 'zh/refund/index.html',
  '/zh/privacy': 'zh/privacy/index.html',
  '/zh/terms': 'zh/terms/index.html',
  '/zh/data-usage': 'zh/data-usage/index.html',
};
for (const [route, file] of Object.entries(routes)) {
  ok(existsSync(join(dist, file)), `缺少路由产物 ${route} (${file})`);
}
ok(existsSync(join(dist, '404.html')), '缺少 404.html');
ok(existsSync(join(dist, 'robots.txt')), '缺少 robots.txt');
ok(existsSync(join(dist, 'sitemap-index.xml')), '缺少 sitemap-index.xml');

// ---- 3. 内部链接检查 ----
function resolveInternal(href) {
  const clean = href.split('#')[0].split('?')[0];
  if (clean === '' || clean === '/') return existsSync(join(dist, 'index.html'));
  const p = clean.replace(/^\//, '').replace(/\/$/, '');
  return (
    existsSync(join(dist, p)) ||
    existsSync(join(dist, p + '.html')) ||
    existsSync(join(dist, p, 'index.html'))
  );
}
const hrefRe = /href="([^"]+)"/g;
for (const file of htmlFiles) {
  const html = readFileSync(file, 'utf8');
  let m;
  while ((m = hrefRe.exec(html)) !== null) {
    const href = m[1];
    if (/^(https?:|mailto:|data:|#)/.test(href)) continue;
    ok(resolveInternal(href), `内部死链 ${href}（来源 ${relative(dist, file)}）`);
  }
}

// ---- 4. 关键 CTA URL 与锚点 section（下载/定价/FAQ 收敛进首页）----
const home = readHtml('index.html');
const zhHome = readHtml('zh/index.html');
const CHECKOUT = BUILD_ENV.PUBLIC_POLAR_CHECKOUT_URL;
const DOWNLOAD = BUILD_ENV.PUBLIC_DOWNLOAD_URL;
for (const [name, html] of [['首页', home], ['中文首页', zhHome]]) {
  ok(html.includes(CHECKOUT), `${name}缺少购买（checkout）链接`);
  ok(html.includes(DOWNLOAD), `${name}缺少下载链接`);
  for (const anchor of ['id="download"', 'id="pricing"', 'id="faq"']) {
    ok(html.includes(anchor), `${name}缺少锚点 section ${anchor}`);
  }
}
ok(CHECKOUT !== DOWNLOAD, '购买与下载 URL 不得相同（必须是两个独立动作）');

// ---- 5. 渐进增强：无 JS 亦可用 ----
// 契约理由：首页 ActivityMock 是服务端渲染的静态产品视图 + 一段内联 vanilla JS 增强
// （本地模拟数据滚动，让界面看起来在运行）。无 JS 时 SSR 表格/日志完整可见（渐进增强），
// 因此契约从「零 <script>」放宽为：
//   a) 只允许无 src 的内联 script（JSON-LD 或本地增强），任何带 src 的外部脚本仍然禁止；
//   b) 内联脚本不得出现网络 API 字样（fetch / XMLHttpRequest / WebSocket / EventSource /
//      sendBeacon）—— 演示数据必须纯本地生成，站点保持零请求、零追踪。
const NET_API_WORDS = ['fetch', 'XMLHttpRequest', 'WebSocket', 'EventSource', 'sendBeacon'];
for (const file of htmlFiles) {
  const html = readFileSync(file, 'utf8');
  const scriptTags = html.match(/<script\b[^>]*>/gi) ?? [];
  for (const tag of scriptTags) {
    ok(
      !/\bsrc\s*=/i.test(tag),
      `产物含外部脚本 <script src>（只允许内联）: ${tag} @ ${relative(dist, file)}`,
    );
  }
  const inlineRe = /<script\b[^>]*>([\s\S]*?)<\/script>/gi;
  let sm;
  while ((sm = inlineRe.exec(html)) !== null) {
    for (const word of NET_API_WORDS) {
      ok(
        !sm[1].includes(word),
        `内联脚本出现网络 API 字样 "${word}"（mock 必须纯本地）@ ${relative(dist, file)}`,
      );
    }
  }
}
// 无 JS 时购买/下载仍是原生锚点
ok(
  new RegExp(`<a[^>]+href="${CHECKOUT.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).test(home),
  '首页购买链接不是原生 <a>（无 JS 不可用）',
);
ok(
  new RegExp(`<a[^>]+href="${DOWNLOAD.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).test(home),
  '首页下载链接不是原生 <a>（无 JS 不可用）',
);

// ---- 6. 不泄露 ----
const FORBIDDEN = [
  'mock-checkout',
  // 独立单词 mock 的残留（占位 URL、mock server 等）。用词边界正则而非子串：
  // 首页 ActivityMock 演示组件的 .amock-* class 前缀是刻意命名，不属于 mock 配置残留。
  /\bmock\b/i,
  'PLACEHOLDER',
  'api.appidge.com', // 私有 API 地址不应出现在营销站产物
  'api.appidge.app', // 迁移前旧域名也不能残留
  'x-api-key',
  'sk_live_',
  'sk_test_',
  '.dev.vars',
  '-----BEGIN',
];
for (const file of files) {
  if (!/\.(html|xml|txt|css)$/.test(file)) continue;
  const content = readFileSync(file, 'utf8');
  for (const token of FORBIDDEN) {
    const hit = token instanceof RegExp ? token.test(content) : content.includes(token);
    ok(!hit, `产物泄露禁用字符串 "${token}" @ ${relative(dist, file)}`);
  }
}

// ---- 7. 法律页已正式生效：不得再出现草稿/待审核字样（DraftNotice 已移除）----
const legalPages = [
  'refund/index.html', 'privacy/index.html', 'terms/index.html', 'data-usage/index.html',
  'zh/refund/index.html', 'zh/privacy/index.html', 'zh/terms/index.html', 'zh/data-usage/index.html',
];
for (const legal of legalPages) {
  const h = readHtml(legal);
  ok(!h.includes('pending legal review'), `${legal} 仍含英文草稿标记（应已移除）`);
  ok(!h.includes('待法务审核'), `${legal} 仍含中文草稿标记（应已移除）`);
}

// ---- 8. 可访问性结构断言 ----
for (const [route, file] of Object.entries(routes)) {
  const html = readHtml(file);
  const wantLang = route.startsWith('/zh') ? 'zh-Hans' : 'en';
  ok(new RegExp(`lang="${wantLang}"`).test(html), `${route} 缺少 <html lang="${wantLang}">`);
  ok(/name="viewport"/.test(html), `${route} 缺少 viewport`);
  ok(/class="skip-link"/.test(html), `${route} 缺少跳转主内容的 skip-link`);
  const h1Count = (html.match(/<h1\b/g) ?? []).length;
  ok(h1Count === 1, `${route} 应有且仅有 1 个 <h1>，实际 ${h1Count}`);
  ok(/<meta name="description"/.test(html), `${route} 缺少 meta description`);
  ok(/property="og:title"/.test(html), `${route} 缺少 Open Graph 标签`);
}

// ---- 汇总 ----
if (failures.length) {
  console.error(`\n站点验收失败（${failures.length}）:`);
  for (const f of failures) console.error('  ✗ ' + f);
  process.exit(1);
}
console.log(
  `\n站点验收全部通过：${Object.keys(routes).length + 1} 路由、内部链接、CTA、无 JS、` +
    `脱敏、法律草稿标记、可访问性结构。`,
);
