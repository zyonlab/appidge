/** FAQ 页文案 —— 问题按目标用户真实搜索/提问方式撰写（SEO 长尾词）。 */

export interface FaqCopy {
  title: string;
  metaDescription: string;
  eyebrow: string;
  h2: string;
  /** aHtml 允许内链与强调标记。 */
  items: { q: string; aHtml: string }[];
}

export const faq: Record<'zh' | 'en', FaqCopy> = {
  zh: {
    title: '常见问题',
    metaDescription:
      'Appidge 常见问题：为什么开了全局代理有些软件还是不走代理、支持哪些代理方式、是不是 VPN、和 Clash/Surge 会不会冲突、和 Proxifier 的区别、试用与激活、离线宽限、退款。',
    eyebrow: 'FAQ',
    h2: '常见问题',
    items: [
      {
        q: '为什么开了全局代理，有些软件还是不走代理？',
        aHtml:
          '因为 macOS 的「系统代理」全凭应用自觉。自带网络栈的应用（很多 AI 客户端）、开发工具链（pip、npm、Go）、后台守护进程（比如 Docker）都会绕开它直接连。Appidge 在系统网络层按进程拦流量，它们认不认系统代理都一样，走向由你的规则说了算。',
      },
      {
        q: '支持哪些代理方式？',
        aHtml:
          '配合你手上的任何常见代理使用——Clash、Surge 或其他代理客户端都行，透明代理、匿名代理也支持，还可以配置<strong>代理链</strong>（多级代理串联）。Appidge 只负责把进程流量转过去，上游用什么由你决定。',
      },
      {
        q: 'Appidge 是 VPN 吗？提供节点吗？',
        aHtml:
          '都不是。Appidge 不提供也不销售任何节点、服务器或流量中转服务。它是个本机工具：只在你的 Mac 上，把进程流量按规则转给<strong>你自己配置的代理</strong>，或直连。没配代理的时候，它变不出网络通道来。',
      },
      {
        q: '会和 Clash、Surge 这些代理软件冲突吗？',
        aHtml:
          '不会，它们是搭配着用的。你的代理软件负责出站，Appidge 负责决定哪个进程的哪个连接交给它。代理软件自己的流量会被自动识别放行，不会绕回自己变成死循环。',
      },
      {
        q: '和 Proxifier 有什么区别？',
        aHtml:
          '做的是同一类事：进程级代理转发。区别在于 Appidge 是基于现代 macOS 重新设计的——基于系统 Network Extension，活动页能实时看到被接管的进程，点一下就能改规则、马上生效，新规则自动覆盖旧的，代理回环也自动处理。装上对比着用最直观。',
      },
      {
        q: '要先买才能用吗？',
        aHtml:
          '不用。<a href="/zh/#download">先下载试用</a>，确认解决了你的问题再买。下载和购买是两回事，结账不会自动装 App。',
      },
      {
        q: '买了之后怎么激活？',
        aHtml:
          '付款后许可证密钥会发到你邮箱（Polar 客户门户里也能查）。打开 Appidge 粘贴密钥就行。密钥存在 macOS 钥匙串里，不落明文。',
      },
      {
        q: '离线还能用吗？',
        aHtml:
          '能。激活后 App 会缓存最近一次有效授权，并提供离线宽限期——短时间没网络、或授权服务临时不可用，都不会立即锁定付费功能。',
      },
      {
        q: '怎么申请退款？',
        aHtml:
          '购买后 14 天内无理由全额退款。发邮件到 <a href="mailto:support@appidge.com">support@appidge.com</a> 带上订单信息就行，我们会尽快处理。详见<a href="/zh/refund">退款政策</a>。',
      },
    ],
  },
  en: {
    title: 'FAQ',
    metaDescription:
      'Appidge FAQ: why some apps bypass your system-wide proxy, which proxy setups are supported, whether it is a VPN, how it works alongside Clash and Surge, how it compares to Proxifier, trial and activation, offline grace period, and refunds.',
    eyebrow: 'FAQ',
    h2: 'Frequently asked questions',
    items: [
      {
        q: 'Why do some apps bypass my system-wide proxy?',
        aHtml:
          'Because macOS proxy settings are honored on a strictly voluntary basis. Apps with their own network stacks (many AI clients), developer toolchains (pip, npm, Go), and background daemons (Docker, for one) connect directly and route around them. Appidge intercepts traffic per process at the system network layer — whether an app respects proxy settings or not, your rules decide where it goes.',
      },
      {
        q: 'Which proxy setups are supported?',
        aHtml:
          'Any proxy you already run — Clash, Surge, or other clients — plus transparent proxies and anonymous proxies, and you can configure <strong>proxy chains</strong> (multiple proxies in sequence). Appidge only forwards process traffic; what sits upstream is up to you.',
      },
      {
        q: 'Is Appidge a VPN? Do you sell nodes?',
        aHtml:
          'Neither. Appidge does not provide or sell nodes, servers, or any traffic relay service. It is a local utility: on your Mac, it forwards process traffic to <strong>the proxy you configured</strong>, or directly, by your rules. Without a proxy configured, it can’t conjure a network path out of thin air.',
      },
      {
        q: 'Will it conflict with Clash or Surge?',
        aHtml:
          'No — they work together. Your proxy client handles the outbound leg; Appidge decides which process’s connections to hand to it. Your proxy’s own traffic is recognized and passed through, so nothing loops back on itself.',
      },
      {
        q: 'How is it different from Proxifier?',
        aHtml:
          'Same kind of job — per-process proxy forwarding — rebuilt for modern macOS: driven by the system’s Network Extension, with a live view of every intercepted process, one-click rule changes that take effect immediately, newest-rule-wins semantics, and automatic loopback handling. The quickest way to compare is to run them side by side.',
      },
      {
        q: 'Do I have to pay before trying it?',
        aHtml:
          'No. <a href="/#download">Download the trial</a>, confirm it solves your problem, then buy. Download and purchase are separate steps — checkout doesn’t install anything.',
      },
      {
        q: 'How do I activate after buying?',
        aHtml:
          'Your license key arrives by email after payment (it’s also in the Polar customer portal). Open Appidge and paste the key. It’s stored in the macOS Keychain, never in plain text files.',
      },
      {
        q: 'Does it work offline?',
        aHtml:
          'Yes. After activation the app caches your last valid license check and allows an offline grace period — a spotty connection or a temporarily unreachable licensing service won’t lock you out of paid features.',
      },
      {
        q: 'How do refunds work?',
        aHtml:
          'Full refund within 14 days of purchase, no questions asked. Email <a href="mailto:support@appidge.com">support@appidge.com</a> with your order details and we’ll take care of it. See the <a href="/refund">refund policy</a>.',
      },
    ],
  },
};
