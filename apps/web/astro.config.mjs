// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// 生产站点域名（用于 canonical / sitemap / OG）。非 secret，见 CLAUDE.md 线上拓扑。
const SITE_URL = 'https://appidge.app';

export default defineConfig({
  site: SITE_URL,
  output: 'static',
  trailingSlash: 'ignore',
  build: {
    // 输出干净的 /page/index.html，链接使用无扩展名路径
    format: 'directory',
  },
  // 纯静态营销站：不引入任何客户端框架、无 SSR、无追踪脚本。
  integrations: [sitemap()],
  devToolbar: { enabled: false },
});
