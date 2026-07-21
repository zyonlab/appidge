#!/usr/bin/env node
/**
 * 站点验收测试（CLAUDE.md §6 Website 必测）。
 *
 * 用【生产式的公开配置】重建站点（注入 process.env，覆盖本地 mock 的 .env），随后对产物断言：
 *  - production build 成功（本脚本负责触发一次干净构建）。
 *  - 八条路由产物齐全，含 404。
 *  - 内部链接全部指向存在的产物文件。
 *  - 关键 CTA：首页/定价含购买链接，下载/定价含下载链接；购买与下载是两个不同 URL。
 *  - 无 JS 亦可用：产物不含运行时 <script>（仅允许 JSON-LD），核心内容与购买/下载均为原生 <a>。
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

// 生产式公开配置（非 secret，非 mock）。注入 process.env 使其优先于本地 .env。
const BUILD_ENV = {
  PUBLIC_CREEM_CHECKOUT_URL: 'https://www.creem.io/payment/appidge-license',
  PUBLIC_API_BASE_URL: 'https://api.appidge.app',
  PUBLIC_DOWNLOAD_URL: 'https://updates.appidge.app',
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
const routes = {
  '/': 'index.html',
  '/download': 'download/index.html',
  '/pricing': 'pricing/index.html',
  '/faq': 'faq/index.html',
  '/refund': 'refund/index.html',
  '/privacy': 'privacy/index.html',
  '/terms': 'terms/index.html',
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

// ---- 4. 关键 CTA URL ----
const home = readHtml('index.html');
const pricing = readHtml('pricing/index.html');
const download = readHtml('download/index.html');
const CHECKOUT = BUILD_ENV.PUBLIC_CREEM_CHECKOUT_URL;
const DOWNLOAD = BUILD_ENV.PUBLIC_DOWNLOAD_URL;
ok(home.includes(CHECKOUT), '首页缺少购买（checkout）链接');
ok(pricing.includes(CHECKOUT), '定价页缺少购买（checkout）链接');
ok(pricing.includes(DOWNLOAD), '定价页缺少下载链接');
ok(download.includes(DOWNLOAD), '下载页缺少下载链接');
ok(CHECKOUT !== DOWNLOAD, '购买与下载 URL 不得相同（必须是两个独立动作）');

// ---- 5. 无 JS 亦可用 ----
for (const file of htmlFiles) {
  const html = readFileSync(file, 'utf8');
  const scripts = html.match(/<script\b[^>]*>/gi) ?? [];
  for (const tag of scripts) {
    ok(
      /type="application\/ld\+json"/i.test(tag),
      `产物含运行时 <script>（应为纯静态）: ${tag} @ ${relative(dist, file)}`,
    );
  }
}
// 无 JS 时购买/下载仍是原生锚点
ok(
  new RegExp(`<a[^>]+href="${CHECKOUT.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).test(home),
  '首页购买链接不是原生 <a>（无 JS 不可用）',
);
ok(
  new RegExp(`<a[^>]+href="${DOWNLOAD.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}"`).test(download),
  '下载页下载链接不是原生 <a>（无 JS 不可用）',
);

// ---- 6. 不泄露 ----
const FORBIDDEN = [
  'mock-checkout',
  'mock', // 任何 mock 残留
  'PLACEHOLDER',
  'api.appidge.app', // 私有 API 地址不应出现在营销站产物
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
    ok(!content.includes(token), `产物泄露禁用字符串 "${token}" @ ${relative(dist, file)}`);
  }
}

// ---- 7. 法律页草稿标记 ----
for (const legal of ['refund/index.html', 'privacy/index.html', 'terms/index.html']) {
  ok(readHtml(legal).includes('待法务审核'), `${legal} 缺少草稿/待法务审核标记`);
}

// ---- 8. 可访问性结构断言 ----
for (const [route, file] of Object.entries(routes)) {
  const html = readHtml(file);
  ok(/lang="zh-Hans"/.test(html), `${route} 缺少 <html lang>`);
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
