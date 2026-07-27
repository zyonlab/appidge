/** 定价页文案。 */

export interface PricingCopy {
  title: string;
  metaDescription: string;
  eyebrow: string;
  h2: string;
  sub: string;
  card: {
    tag: string;
    name: string;
    /** 大字价格（如 "US$3.99"）。 */
    price: string;
    /** 价格后缀（授权范围，如 "／3 台 Mac"）。 */
    priceSuffix: string;
    priceLine: string;
    feats: string[];
    ctaBuy: string;
    ctaTry: string;
    refundHtml: string;
    fine: string;
  };
  activate: { title: string; body: string }[];
  refundLink: string;
}

export const pricing: Record<'zh' | 'en', PricingCopy> = {
  zh: {
    title: '定价',
    metaDescription:
      'Appidge 许可证 US$3.99，可激活 3 台 Mac。先免费下载试用，觉得好再通过 Creem 安全结账购买。14 天无理由退款。币种与税费以结账页显示为准。',
    eyebrow: '定价',
    h2: '先用，觉得好再买',
    sub: '下载和购买是两回事：先装上试试，确认解决了你的问题，再买许可证解锁。',
    card: {
      tag: 'License',
      name: 'Appidge 许可证',
      price: 'US$3.99',
      priceSuffix: '／可激活 3 台 Mac',
      priceLine: '币种与税费以 Creem 结账页显示为准',
      feats: [
        '按进程接管流量，规则说了算',
        '点击进程改规则，当场生效',
        '透明代理、匿名代理、代理链都支持',
        '代理回环自动处理，应用内自动更新',
      ],
      ctaBuy: '购买许可证',
      ctaTry: '先下载试用',
      refundHtml:
        '✓ <b>14 天内无理由全额退款</b>——遇到任何问题先发邮件，我们会尽快处理。',
      fine: '结账由 Creem 安全处理。许可证解锁的是软件功能，不包含任何网络或节点服务。',
    },
    activate: [
      {
        title: '在 Creem 结账页完成付款',
        body: '点击「购买许可证」，跳转到 Creem 托管的安全结账页面。',
      },
      {
        title: '邮件收取许可证密钥',
        body: '付款成功后密钥发送到你的邮箱，也可在 Creem 客户门户查看。',
      },
      {
        title: '粘贴密钥，激活完成',
        body: '打开 Appidge 粘贴密钥即可解锁。密钥安全保存在 macOS 钥匙串中。',
      },
    ],
    refundLink: '查看退款政策',
  },
  en: {
    title: 'Pricing',
    metaDescription:
      'Appidge license: $3.99 for 3 Macs. Download the free trial first, then buy through Creem’s secure checkout when it earns its keep. 14-day refund, no questions asked. Currency and tax are shown at checkout.',
    eyebrow: 'Pricing',
    h2: 'Try it first. Buy it when it earns its keep.',
    sub: 'Download and purchase are separate steps: install it, confirm it solves your problem, then unlock it with a license.',
    card: {
      tag: 'License',
      name: 'Appidge License',
      price: '$3.99',
      priceSuffix: 'for 3 Macs',
      priceLine: 'Currency and tax are shown on the Creem checkout page',
      feats: [
        'Per-process traffic interception — your rules decide',
        'Click a process to change its route, effective immediately',
        'Transparent proxies, anonymous proxies, and proxy chains supported',
        'Automatic loopback handling and in-app updates',
      ],
      ctaBuy: 'Buy a license',
      ctaTry: 'Download the trial first',
      refundHtml:
        '✓ <b>Full refund within 14 days, no questions asked</b> — email us about any problem and we’ll sort it out.',
      fine: 'Checkout is handled securely by Creem. A license unlocks software features; it does not include any network or node service.',
    },
    activate: [
      {
        title: 'Pay through Creem checkout',
        body: 'Click “Buy a license” to open Creem’s hosted, secure checkout page.',
      },
      {
        title: 'Get your license key by email',
        body: 'The key arrives in your inbox after payment — it’s also available in the Creem customer portal.',
      },
      {
        title: 'Paste the key to activate',
        body: 'Open Appidge and paste the key to unlock. It’s stored safely in the macOS Keychain.',
      },
    ],
    refundLink: 'Read the refund policy',
  },
};
