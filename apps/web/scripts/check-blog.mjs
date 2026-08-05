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
 * 用法：
 *   node scripts/check-blog.mjs              # 全部断言
 *   node scripts/check-blog.mjs --routes     # 只跑路由产物
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

// ---- 1. 引擎挂载点产出 ----
// 引擎在 mount 下有两层：`/zh/blog/`（landing）与 `/zh/blog/<route>/`（内容类型归档）。
// 这一条是「引擎到底有没有挂上」的最小证据，其余路由随后续任务逐条加进来。
if (only('--routes')) {
  const mountRoot = join(dist, MOUNT.replace(/^\//, ''), 'index.html');
  ok(existsSync(mountRoot), `缺少引擎挂载点产物 ${MOUNT}/（${mountRoot.replace(root + '/', '')}）`);
}

// ---- 汇总 ----
if (failures.length) {
  console.error(`\n博客验收失败（${failures.length}）:`);
  for (const f of failures) console.error('  ✗ ' + f);
  process.exit(1);
}
console.log('\n博客验收全部通过。');
