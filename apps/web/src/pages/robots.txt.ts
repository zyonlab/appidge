import type { APIRoute } from 'astro';
import { SITE_URL } from '../config/site';

/**
 * robots.txt 作为构建期端点生成（而非 public/ 静态文件），
 * 使 Sitemap 域名与 canonical/OG/sitemap 同源于 PUBLIC_SITE_URL，
 * 避免再次出现硬编码/冲突域名。SITE_URL 末尾无斜杠。
 */
export const GET: APIRoute = () => {
  const body = `User-agent: *
Allow: /

Sitemap: ${SITE_URL}/sitemap-index.xml
`;
  return new Response(body, {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
