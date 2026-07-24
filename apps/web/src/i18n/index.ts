/**
 * i18n 基础设施 —— 纯静态双语：
 *  - 英文（默认）：根路径（/、/pricing、/faq …），x-default 指向英文
 *  - 中文：/zh/ 前缀（/zh/、/zh/pricing …）
 * 每页文案字典放 src/i18n/<page>.ts，UI 公共字符串在本文件。
 */

export type Locale = 'zh' | 'en';

export const LOCALES: readonly Locale[] = ['zh', 'en'] as const;

/** <html lang> 值。 */
export const HTML_LANG: Record<Locale, string> = {
  zh: 'zh-Hans',
  en: 'en',
};

/** og:locale 值。 */
export const OG_LOCALE: Record<Locale, string> = {
  zh: 'zh_CN',
  en: 'en_US',
};

/** hreflang 值（与 sitemap i18n 配置保持一致）。 */
export const HREFLANG: Record<Locale, string> = {
  zh: 'zh-Hans',
  en: 'en',
};

/**
 * 由「locale 无关的逻辑路径」得到该 locale 的真实路径。
 * localePath('en', '/pricing') === '/pricing'
 * localePath('zh', '/pricing') === '/zh/pricing'
 * localePath('zh', '/') === '/zh/'
 */
export function localePath(locale: Locale, path: string): string {
  if (locale === 'en') return path;
  return path === '/' ? '/zh/' : `/zh${path}`;
}

/** 站点级 UI 字符串（Header / Footer / 布局）。 */
export const ui = {
  zh: {
    skipToContent: '跳到主内容',
    nav: {
      home: '首页',
      download: '下载',
      pricing: '定价',
      faq: '常见问题',
      refund: '退款政策',
    },
    navCta: '下载 App',
    langSwitch: { label: 'English', title: 'Switch to English' },
    legal: {
      heading: '法律条款',
      refund: '退款政策',
      privacy: '隐私政策',
      terms: '服务条款',
    },
    footer: {
      blurb:
        'macOS 按进程代理转发工具：接管进程网络，按你的规则决定每个连接转给你自己的代理还是直连。支持透明代理、匿名代理与代理链。非 VPN，不提供任何节点或网络服务。',
      product: '产品',
      support: '支持',
      legal: '法律',
      privacy: '隐私政策',
      terms: '服务条款',
      meta: '结账由 Polar（Merchant of Record）处理 · 本产品不提供 VPN 或代理节点服务',
      trademark:
        'Proxifier、Clash、Surge 及本站提及的其他名称均为其各自所有者的商标，仅用于说明兼容性或类别，与本产品无关联、亦未获其背书。',
      rights: '保留所有权利。',
    },
  },
  en: {
    skipToContent: 'Skip to content',
    nav: {
      home: 'Home',
      download: 'Download',
      pricing: 'Pricing',
      faq: 'FAQ',
      refund: 'Refunds',
    },
    navCta: 'Download',
    langSwitch: { label: '中文', title: '切换到中文' },
    legal: {
      heading: 'Legal',
      refund: 'Refund Policy',
      privacy: 'Privacy Policy',
      terms: 'Terms of Service',
    },
    footer: {
      blurb:
        'Per-process proxy forwarding for macOS: intercept each process’s traffic and route it to your own proxy — or directly — by your rules. Transparent proxies, anonymous proxies, and proxy chains supported. Not a VPN; no nodes or network services included.',
      product: 'Product',
      support: 'Support',
      legal: 'Legal',
      privacy: 'Privacy Policy',
      terms: 'Terms of Service',
      meta: 'Checkout handled by Polar (Merchant of Record) · This product provides no VPN or proxy node service',
      trademark:
        'Proxifier, Clash, Surge, and other names mentioned on this site are trademarks of their respective owners, used only to indicate compatibility or category. Appidge is not affiliated with or endorsed by any of them.',
      rights: 'All rights reserved.',
    },
  },
} as const;
