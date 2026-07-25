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
  | 'PUBLIC_SITE_URL'
  | 'PUBLIC_POLAR_CHECKOUT_URL'
  | 'PUBLIC_API_BASE_URL'
  | 'PUBLIC_DOWNLOAD_URL';

const REQUIRED_KEYS: RequiredEnvKey[] = [
  'PUBLIC_SITE_URL',
  'PUBLIC_POLAR_CHECKOUT_URL',
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

/**
 * Creem 支付链接（购买）。公开链接，非 API key。
 * 注：常量/环境变量名沿用 POLAR_*（历史命名）——改名会牵动 components 与 check-site
 * （另一 agent 所有权），列为后续债务，见 docs/creem-integration.md。
 */
export const POLAR_CHECKOUT_URL = values.PUBLIC_POLAR_CHECKOUT_URL;

/**
 * License Worker facade base（生产 https://api.appidge.com）。
 * 注意：本站为纯静态营销站，【不】把该地址渲染进任何页面——由 macOS App 使用。
 * 此处仅做「构建期存在性校验」，防止部署环境缺配置。leak 测试会断言它不出现在产物 HTML 中。
 */
export const API_BASE_URL = values.PUBLIC_API_BASE_URL;

/** 下载：R2 自定义域名，直达更新产物（不经 Worker）。 */
export const DOWNLOAD_URL = values.PUBLIC_DOWNLOAD_URL;

/**
 * 站点 canonical 域名（canonical / OG / sitemap）——构建期公开配置，非 secret。
 * staging=https://staging.appidge.com，prod=https://appidge.com。
 * 必须与 astro.config.mjs 的 `site:` 同源于 PUBLIC_SITE_URL，避免 sitemap 与 canonical 域名冲突。
 */
export const SITE_URL = values.PUBLIC_SITE_URL;

/** 支持 / 退款联系邮箱（对外公开）。 */
export const SUPPORT_EMAIL = 'support@appidge.com';

/** 站点常量。 */
export const SITE_NAME = 'Appidge';
/**
 * 站点 tagline（`<title>` 与 JSON-LD description 用）。
 *
 * 定位口径：我们是**流量转发工具**——按进程把流量转发到*用户自己的*代理，或直连、拦截。
 * 不说「代理工具 / proxy control」：前者读起来像「我们就是代理」（与「非 VPN、不含节点」
 * 的红线自相矛盾，也会招来「你们节点在哪」），后者读起来像代理切换/管理器，都不是我们做的事。
 * 「proxy」保留为**目的地**（转给你的代理）而非我们的品类——既准确，也不丢搜索词。
 */
export const SITE_TAGLINE = {
  zh: '按进程把流量转发到你自己的代理',
  en: 'Per-process traffic forwarding for macOS',
} as const;
