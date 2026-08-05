#!/usr/bin/env node
/**
 * 博客验收测试（aifb 引擎挂载在 /zh/blog）。
 *
 * 与 check-site.mjs 的分工：
 *  - check-site.mjs 守【官网零回归】。它 walk 整个 dist，所以内部死链、零外部脚本、
 *    泄露字符串这三条已经自动罩住博客产物 —— 本脚本不重复这些断言。
 *  - 本脚本守【博客自己的产物契约】：路由齐全、构建信息正确、SEO 带 mount 前缀、
 *    三个内容方向达到篇数下限。
 *
 * 用与 check-site.mjs 同一套「生产式公开配置」重建站点，避免两个脚本因构建环境不同
 * 而对同一份产物得出不同结论。
 *
 * 用法（不带参数 = 全部断言）：
 *   --routes       引擎路由产物齐全
 *   --build-info   .aifb/build.json 的 mount / pages 正确
 *   --sitemap      sitemap 收录博客，且不给博客伪造 hreflang
 *   --intent       意图层不变量（site.yaml 不得声明 locales）
 * 后续任务会加上 --coverage（三方向篇数下限）与 --gaps（TOOL-GAPS 的 issue 回填核对）。
 */
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync, rmSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dist = join(root, 'dist');

/** 引擎挂载点。URL 结构已冻结（BRIEF §「URL 结构（已定，非待议）」），不要在这里改。 */
const MOUNT = '/zh/blog';

// 与 check-site.mjs 保持字面一致的生产式公开配置。任一侧改动都要同步另一侧。
const BUILD_ENV = {
  PUBLIC_SITE_URL: process.env.PUBLIC_SITE_URL?.trim() || 'https://appidge.com',
  PUBLIC_POLAR_CHECKOUT_URL:
    process.env.PUBLIC_POLAR_CHECKOUT_URL?.trim() || 'https://checkout.example.invalid/appidge-ci',
  PUBLIC_API_BASE_URL: process.env.PUBLIC_API_BASE_URL?.trim() || 'https://api.appidge.com',
  PUBLIC_DOWNLOAD_URL:
    process.env.PUBLIC_DOWNLOAD_URL?.trim() || 'https://updates.appidge.com/appidge-latest.dmg',
};

const args = new Set(process.argv.slice(2));
const only = (flag) => args.size === 0 || args.has(flag);

const failures = [];
const ok = (cond, msg) => {
  if (!cond) failures.push(msg);
};

// ---- 干净的生产构建 ----
if (existsSync(dist)) rmSync(dist, { recursive: true, force: true });
console.log('· 用生产式公开配置执行 astro build …');
const build = spawnSync('pnpm', ['exec', 'astro', 'build'], {
  cwd: root,
  env: { ...process.env, ...BUILD_ENV },
  stdio: 'inherit',
});
if (build.status !== 0) {
  console.error('构建失败，博客验收终止。');
  process.exit(1);
}

const inDist = (...parts) => join(dist, ...parts);
const mountDir = MOUNT.replace(/^\//, '');

// ---- 1. 引擎路由产物 ----
// 引擎在 mount 下有两层：`/zh/blog/`（landing）与 `/zh/blog/<route>/`（内容类型归档）。
// 这里只列【永久】路由。videos / projects / case-studies 是骨架带来的多余内容类型，
// T-006 会把 content-types.yaml 收敛成单类型，所以不写进断言。
if (only('--routes')) {
  const required = [
    ['index.html', `${MOUNT}/`],
    ['writing/index.html', `${MOUNT}/writing/`],
    ['topics/index.html', `${MOUNT}/topics/`],
    ['series/index.html', `${MOUNT}/series/`],
    ['rss.xml', `${MOUNT}/rss.xml`],
    ['llms.txt', `${MOUNT}/llms.txt`],
  ];
  for (const [file, route] of required) {
    ok(existsSync(inDist(mountDir, file)), `缺少引擎路由产物 ${route}（dist/${mountDir}/${file}）`);
  }
}

// ---- 2. 构建信息 ----
// `.aifb/build.json` 是构建期事实，闸门（aifb validate）靠它把 URL 换算回引擎根。
// 它错了不会报错，只会让一批规则【安静地停止匹配】——所以要显式断言。
if (only('--build-info')) {
  const infoPath = join(root, '.aifb', 'build.json');
  if (!existsSync(infoPath)) {
    failures.push('缺少 .aifb/build.json（引擎未写出构建信息，validate 会按 origin 根换算 URL）');
  } else {
    const info = JSON.parse(readFileSync(infoPath, 'utf8'));
    ok(info.mount === MOUNT, `.aifb/build.json 的 mount 应为 "${MOUNT}"，实际 "${info.mount}"`);
    const pages = [...(info.pages ?? [])].sort().join(',');
    ok(
      pages === 'series,topics',
      `.aifb/build.json 的 pages 应为 topics+series，实际 "${pages}"——` +
        'about/uses/newsletter/work-with-me 是宿主站的事，引擎不该在 /zh/blog 下再开一套',
    );
  }
}

// ---- 3. sitemap 收录博客，且不伪造 hreflang ----
// 宿主站是双语（en 根路径 / zh 前缀），博客只有中文。@astrojs/sitemap 的 i18n 只在
// 【实际存在的 URL 集合】里配对，所以博客不该宣告一个并不存在的英文版。
// 这条一旦破了，等于对搜索引擎撒谎，且很难从产物里一眼看出来。
if (only('--sitemap')) {
  const indexPath = inDist('sitemap-index.xml');
  ok(existsSync(indexPath), '缺少 sitemap-index.xml');
  const shard = inDist('sitemap-0.xml');
  if (!existsSync(shard)) {
    failures.push('缺少 sitemap-0.xml');
  } else {
    const xml = readFileSync(shard, 'utf8');
    ok(xml.includes(`${MOUNT}/`), `sitemap 未收录博客 URL（应含 ${MOUNT}/）`);
    for (const block of xml.match(/<url>[\s\S]*?<\/url>/g) ?? []) {
      // 按 <loc> 判定这条目是不是博客的，而不是拿整个 block 做子串匹配 ——
      // 宿主页的 alternates 里也可能出现博客 URL，那不该算到博客头上。
      const loc = (block.match(/<loc>([^<]*)<\/loc>/) ?? [])[1] ?? '';
      if (!new URL(loc).pathname.startsWith(`${MOUNT}/`)) continue;
      ok(
        !block.includes('xhtml:link'),
        `sitemap 给博客 URL 输出了 hreflang alternates —— 博客只有中文，` +
          `不得宣告不存在的英文版：${loc}`,
      );
    }
  }
}

// ---- 4. 意图层不变量：语言由 mount 承载，site.yaml 不得再声明 locales ----
// 宿主站已双语，我们把单语引擎挂在 /zh/blog —— 语言已经在 mount 里了。
// 再声明 locales 会产出 /zh/blog/zh/（见 aifb docs/specs/engine-options.md）。
// 这是个只在【将来某次改配置时】才会踩到的坑，所以用断言钉住，而不是写句注释。
if (only('--intent')) {
  const siteYaml = readFileSync(join(root, 'site', 'site.yaml'), 'utf8');
  const declaresLocales = /^locales:/m.test(siteYaml);
  ok(
    !declaresLocales,
    'site/site.yaml 声明了 locales —— 语言已经由 mount(/zh/blog) 承载，' +
      '再声明一次会产出 /zh/blog/zh/',
  );
}

// ---- 汇总 ----
if (failures.length) {
  console.error(`\n博客验收失败（${failures.length}）:`);
  for (const f of failures) console.error('  ✗ ' + f);
  process.exit(1);
}
console.log('\n博客验收全部通过。');
