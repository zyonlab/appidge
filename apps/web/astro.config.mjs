// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// 站点 canonical 域名（用于 canonical / sitemap / OG）——构建期公开配置，非 secret。
// 单一真相源：与 src/config/site.ts 同读 PUBLIC_SITE_URL，避免 sitemap 与 canonical 域名冲突。
// staging=https://staging.appidge.com，prod=https://appidge.com。缺失即让 build 失败，不回退错误域名。
//
// 说明：这里不用 vite 的 loadEnv —— pnpm 严格 node_modules 下 `vite` 不会 hoist 到 apps/web，
// 无法从 config 裸导入。改为内联读取 .env（语义与 loadEnv 一致：.env 提供默认值，
// process.env 覆盖之，使 check-site.mjs 注入的生产配置优先）。
function readPublicSiteUrl() {
  // process.env 优先（CI / check-site.mjs 注入的生产式配置）。
  const fromProcess = process.env.PUBLIC_SITE_URL?.trim();
  if (fromProcess) return fromProcess;
  // 回退到本地 .env 文件（git-ignored）。
  try {
    const envPath = fileURLToPath(new URL('.env', import.meta.url));
    const text = readFileSync(envPath, 'utf8');
    for (const line of text.split('\n')) {
      const m = line.match(/^\s*PUBLIC_SITE_URL\s*=\s*(.*)\s*$/);
      if (m) return m[1].replace(/^['"]|['"]$/g, '').trim();
    }
  } catch {
    /* 无 .env 文件时落到下面的抛错 */
  }
  return '';
}

const SITE_URL = readPublicSiteUrl();
if (!SITE_URL) {
  throw new Error(
    '[appidge/web] 缺少构建期公开配置 PUBLIC_SITE_URL（参考 apps/web/.env.example）。' +
      '构建拒绝在缺失配置时继续，以免 sitemap 指向错误的生产域名。',
  );
}

export default defineConfig({
  site: SITE_URL,
  output: 'static',
  trailingSlash: 'ignore',
  build: {
    // 输出干净的 /page/index.html，链接使用无扩展名路径
    format: 'directory',
  },
  // 纯静态营销站：不引入任何客户端框架、无 SSR、无追踪脚本。
  // sitemap i18n：英文在根路径（默认），中文在 /zh/ 前缀；hreflang 与 BaseLayout 内的
  // <link rel="alternate"> 保持同一映射。
  integrations: [
    sitemap({
      i18n: {
        defaultLocale: 'en',
        locales: { en: 'en', zh: 'zh-Hans' },
      },
    }),
  ],
  devToolbar: { enabled: false },
});
