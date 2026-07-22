/**
 * 构建期公开配置 —— 单一真相源。
 *
 * 这里读取三个 PUBLIC_* 构建期变量（会进入静态产物、对用户可见，因此【非 secret】）。
 * 任一缺失/为空时，本模块在 import 阶段抛错，从而让 `astro build` 直接失败——
 * 绝不静默回退到错误的生产地址。所有页面经 BaseLayout 间接 import 本模块，覆盖全站构建。
 *
 * 见 CLAUDE.md §5.2。
 */

type RequiredEnvKey =
  | 'PUBLIC_CREEM_CHECKOUT_URL'
  | 'PUBLIC_API_BASE_URL'
  | 'PUBLIC_DOWNLOAD_URL';

const REQUIRED_KEYS: RequiredEnvKey[] = [
  'PUBLIC_CREEM_CHECKOUT_URL',
  'PUBLIC_API_BASE_URL',
  'PUBLIC_DOWNLOAD_URL',
];

function readRequired(key: RequiredEnvKey): string {
  const raw = import.meta.env[key];
  const value = typeof raw === 'string' ? raw.trim() : '';
  if (value === '') {
    throw new Error(
      `[appidge/web] 缺少构建期公开配置 ${key}。请在 apps/web/.env 填入有效值` +
        `（参考 apps/web/.env.example）。构建拒绝在缺失配置时继续，以免指向错误的生产地址。`,
    );
  }
  return value;
}

function assertHttpsUrl(key: RequiredEnvKey, value: string): string {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error(`[appidge/web] ${key} 不是合法 URL：${value}`);
  }
  if (url.protocol !== 'https:') {
    throw new Error(`[appidge/web] ${key} 必须使用 https：${value}`);
  }
  return value;
}

const values = Object.fromEntries(
  REQUIRED_KEYS.map((k) => [k, assertHttpsUrl(k, readRequired(k))]),
) as Record<RequiredEnvKey, string>;

/** Creem Hosted Checkout Link（购买）。公开链接，非 API key。 */
export const CREEM_CHECKOUT_URL = values.PUBLIC_CREEM_CHECKOUT_URL;

/**
 * License Worker facade base（生产 https://api.appidge.app）。
 * 注意：本站为纯静态营销站，【不】把该地址渲染进任何页面——由 macOS App 使用。
 * 此处仅做「构建期存在性校验」，防止部署环境缺配置。leak 测试会断言它不出现在产物 HTML 中。
 */
export const API_BASE_URL = values.PUBLIC_API_BASE_URL;

/** 下载：R2 自定义域名，直达更新产物（不经 Worker）。 */
export const DOWNLOAD_URL = values.PUBLIC_DOWNLOAD_URL;

/** 生产站点域名（canonical / OG / sitemap）。 */
export const SITE_URL = 'https://appidge.com';

/** 支持 / 退款联系邮箱（对外公开）。 */
export const SUPPORT_EMAIL = 'support@appidge.com';

/** 站点常量。 */
export const SITE_NAME = 'Appidge';
export const SITE_TAGLINE = '按进程控制网络去向';
