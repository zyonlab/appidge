#!/usr/bin/env node
/**
 * 轻量、确定性的项目 lint —— 面向本站的真实约束，而非通用风格：
 *  1. 每个页面（404 除外可选）都必须经 BaseLayout 渲染，保证 SEO/skip-link/结构一致。
 *  2. src 源码内不得出现疑似 secret 的模式（防御性）。
 *  3. .env.example 必须声明四个 PUBLIC_* 构建期变量。
 * 违规即以非零码退出，供 turbo lint 捕获。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const errors = [];

function walk(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    if (statSync(p).isDirectory()) out.push(...walk(p));
    else out.push(p);
  }
  return out;
}

// 1. 页面必须使用 BaseLayout
const pagesDir = join(root, 'src', 'pages');
for (const file of walk(pagesDir)) {
  if (!file.endsWith('.astro')) continue;
  const src = readFileSync(file, 'utf8');
  if (!/BaseLayout/.test(src)) {
    errors.push(`页面未使用 BaseLayout: ${file}`);
  }
}

// 2. secret 模式扫描
const SECRET_PATTERNS = [
  /-----BEGIN [A-Z ]*PRIVATE KEY-----/,
  /\bx-api-key\b/i,
  /\bsk_(live|test)_[A-Za-z0-9]/,
  /\bpolar_[a-z]{2,5}_/i,
  /\bcreem_(test|live)_/,
  /webhook[_-]?secret\s*[:=]\s*['"][^'"]+['"]/i,
];
for (const file of walk(join(root, 'src'))) {
  if (!/\.(astro|ts|mjs|js|css)$/.test(file)) continue;
  const src = readFileSync(file, 'utf8');
  for (const re of SECRET_PATTERNS) {
    if (re.test(src)) errors.push(`疑似 secret 模式 ${re} 出现在 ${file}`);
  }
}

// 3. .env.example 声明三个必需变量
const example = readFileSync(join(root, '.env.example'), 'utf8');
for (const key of [
  'PUBLIC_SITE_URL',
  'PUBLIC_POLAR_CHECKOUT_URL',
  'PUBLIC_API_BASE_URL',
  'PUBLIC_DOWNLOAD_URL',
]) {
  if (!new RegExp(`^${key}=`, 'm').test(example)) {
    errors.push(`.env.example 缺少 ${key}`);
  }
}

if (errors.length) {
  console.error('lint 失败:');
  for (const e of errors) console.error('  - ' + e);
  process.exit(1);
}
console.log('lint 通过：页面结构、secret 扫描、env.example 均合规。');
