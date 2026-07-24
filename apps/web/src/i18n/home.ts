/** 首页文案 —— 中文为源语言（定稿于设计原型 v5），英文为地道翻译而非直译。 */

export interface HomeCopy {
  metaDescription: string;
  hero: {
    chip: string;
    h1Pain: string;
    h1Em: string;
    subHtml: string;
    ctaDownload: string;
    ctaBuy: string;
    noteHtml: string;
  };
  panel: {
    title: string;
    live: string;
    thProcess: string;
    thDest: string;
    thRoute: string;
    thTraffic: string;
    badgeProxy: string;
    badgeDirect: string;
    loopName: string;
    loopDest: string;
    badgeLoop: string;
    rulesHead: string;
    ruleProxy: string;
    ruleDirect: string;
    stateLatest: string;
    stateOverridden: string;
    captionHtml: string;
  };
  scenes: {
    eyebrow: string;
    h2: string;
    sub: string;
    hotTag: string;
    cards: { title: string; hot?: boolean; body: string; tools: string[] }[];
  };
  how: {
    eyebrow: string;
    h2: string;
    sub: string;
    steps: { n: string; title: string; body: string }[];
  };
  compare: {
    eyebrow: string;
    h2: string;
    thApproach: string;
    thCoverage: string;
    thGranularity: string;
    thCost: string;
    rows: {
      name: string;
      coverage: string;
      coverageMark: 'yes' | 'no' | 'part';
      granularity: string;
      granularityMark: 'yes' | 'no' | 'part';
      cost: string;
      highlight?: boolean;
    }[];
    noteHtml: string;
  };
  notvpn: {
    eyebrow: string;
    h2: string;
    sub: string;
    points: { sign: 'no' | 'yes'; title: string; body: string }[];
  };
  cta: {
    eyebrow: string;
    h2: string;
    sub: string;
    ctaDownload: string;
    ctaBuy: string;
  };
}

export const home: Record<'zh' | 'en', HomeCopy> = {
  zh: {
    metaDescription:
      '全局代理开着，AI 客户端、Docker、pip 照样连不上？Appidge 在 macOS 上按进程接管网络，把不认系统代理的应用强制转给你自己的代理，支持透明代理与代理链。非 VPN、不含节点，先下载试用。',
    hero: {
      chip: 'macOS 进程级代理工具 · 配合你手上的任何代理 · 透明代理 / 代理链都支持',
      h1Pain: '全局代理开着，Claude、Docker、pip 照样连不上？',
      h1Em: '按进程抓流量，强制转给你的代理',
      subHtml:
        '这些软件<strong>根本不理会系统代理</strong>。Appidge 在系统网络层把进程流量拦下来，转给<strong>你自己的 Clash、Surge 或任何代理</strong>——透明代理、匿名代理、代理链都行。该直连的写条规则就直连，点一下进程当场生效。',
      ctaDownload: '免费下载试用',
      ctaBuy: '购买许可证',
      noteHtml: '<b>先用，觉得好再买</b> · 14 天无理由退款 · 不含节点，流量出口永远是你自己的',
    },
    panel: {
      title: 'Appidge — 活动进程',
      live: 'LIVE',
      thProcess: '进程',
      thDest: '目标地',
      thRoute: '路由',
      thTraffic: '流量',
      badgeProxy: '走代理',
      badgeDirect: '直连',
      loopName: '你的代理客户端',
      loopDest: '代理自身出站',
      badgeLoop: '◌ 回环已排除',
      rulesHead: '规则 · 按时间倒序 · 最新覆盖旧',
      ruleProxy: '走代理',
      ruleDirect: '直连',
      stateLatest: '最新生效',
      stateOverridden: '已覆盖',
      captionHtml:
        '<b>活动页里点一下进程</b>，路由当场切换——新规则立即生效，自动覆盖旧规则',
    },
    scenes: {
      eyebrow: '这些坑你多半踩过',
      h2: '系统代理对很多软件来说，就是个摆设',
      sub: 'macOS 的系统代理全凭应用自觉。自带网络栈的客户端、语言运行时、后台守护进程，想绕就绕。Appidge 在系统网络层拦流量，不给它们绕的机会。',
      hotTag: '重灾区',
      cards: [
        {
          title: 'AI 客户端与编辑器',
          hot: true,
          body: '这类客户端自己实现网络请求，代理配了等于没配——登录转圈、消息发不出去是常事。',
          tools: ['Claude Desktop', 'ChatGPT App', 'Cursor'],
        },
        {
          title: '模型与数据下载',
          hot: true,
          body: '模型权重动辄几十 GB，直连下到一半断掉，前功尽弃。强制走代理，跑满带宽一次下完。',
          tools: ['Hugging Face', 'Ollama', 'conda'],
        },
        {
          title: 'Docker 与容器',
          body: '守护进程不认你终端里 export 的代理，pull 个镜像能卡半天。',
          tools: ['Docker Desktop', 'OrbStack', 'Colima'],
        },
        {
          title: '语言包管理器',
          body: 'pip 一套配置、npm 一套、Cargo 又一套，配完还经常失效。现在一条规则管所有。',
          tools: ['pip', 'npm', 'Cargo', 'Go', 'Homebrew'],
        },
        {
          title: '终端与 CLI',
          body: 'git clone 卡住才想起来没配代理？那些环境变量，以后不用再记了。',
          tools: ['git', 'curl', 'ssh', 'gh'],
        },
        {
          title: '科研与学术工具',
          body: '文献同步转圈、数据集拉不下来。按进程指定走向，清清楚楚。',
          tools: ['Zotero', 'EndNote', '数据集同步'],
        },
      ],
    },
    how: {
      eyebrow: '工作原理',
      h2: '拦截、判断、放行，都在一个地方',
      sub: '基于系统 Network Extension，所有进程的连接先过 Appidge 的规则引擎——应用认不认系统代理，都得走这一道。',
      steps: [
        {
          n: '01 · 拦截',
          title: '按进程接管流量',
          body: '在系统网络层接管进程连接。配了代理默认就走代理，不用一个个设；代理软件自己的流量会自动放行，不会绕成死循环。',
        },
        {
          n: '02 · 判断',
          title: '按目标地写规则',
          body: '规则写给目的地：某些域名走代理，内网、镜像源直连。上游接你自己的代理，透明代理、匿名代理、代理链都支持。',
        },
        {
          n: '03 · 放行',
          title: '点击进程，当场改规则',
          body: '活动页能看到每个被接管的进程，点一下就能改它的走向，马上生效。新规则自动覆盖旧的，不用回头清理。',
        },
      ],
    },
    compare: {
      eyebrow: '方案对比',
      h2: '三种让应用走代理的方式',
      thApproach: '方式',
      thCoverage: '覆盖不读系统代理的应用',
      thGranularity: '按进程精细控制',
      thCost: '改规则的成本',
      rows: [
        {
          name: '系统代理设置',
          coverage: '应用可自行无视',
          coverageMark: 'no',
          granularity: '全局一刀切',
          granularityMark: 'no',
          cost: '低，但覆盖不全',
        },
        {
          name: '逐个应用配置',
          coverage: '取决于应用是否支持',
          coverageMark: 'part',
          granularity: '每个应用一套配法',
          granularityMark: 'part',
          cost: '高，碎片化、易漏',
        },
        {
          name: 'Appidge 按进程接管',
          coverage: '系统网络层强制接管',
          coverageMark: 'yes',
          granularity: '点击进程即改，即时生效',
          granularityMark: 'yes',
          cost: '一处规则，最新覆盖旧',
          highlight: true,
        },
      ],
      noteHtml:
        '用过 Proxifier？Appidge 做的是同一类事——进程级代理转发——但基于现代 macOS 重新设计：Network Extension 驱动、活动进程看得见、点一下就改规则、代理回环自动处理。可以先下载对比着用。',
    },
    notvpn: {
      eyebrow: '先把话说清楚',
      h2: 'Appidge 不是 VPN',
      sub: '它只是个本机工具，负责把进程流量转给你自己的代理。出口永远是你自己的。',
      points: [
        {
          sign: 'no',
          title: '没有节点，也不卖节点',
          body: '不含任何服务器、节点或订阅流量服务。',
        },
        {
          sign: 'no',
          title: '你的流量不经过我们',
          body: '转发只发生在你的 Mac 本地——交给你配置的代理，或者直连。',
        },
        {
          sign: 'yes',
          title: '只做进程级流量转发',
          body: '没配代理的时候，它也变不出网络通道来。',
        },
      ],
    },
    cta: {
      eyebrow: '开始使用',
      h2: '让每个进程都听你的规则',
      sub: '先下载装上，看看那些一直连不上的软件是不是都通了；觉得值，再买许可证。',
      ctaDownload: '免费下载试用',
      ctaBuy: '查看定价',
    },
  },
  en: {
    metaDescription:
      "Proxy's on system-wide, yet Claude, Docker, and pip still won't connect? Appidge intercepts traffic per process on macOS and forces apps that ignore proxy settings through your own proxy — transparent proxies and proxy chains included. Not a VPN, no bundled nodes. Free trial.",
    hero: {
      chip: 'Per-process proxy control for macOS · Works with any proxy you run',
      h1Pain: "Proxy's on — and Claude, Docker, pip still won't connect?",
      h1Em: 'Force any process through your proxy.',
      subHtml:
        'A lot of software <strong>never reads macOS proxy settings</strong>. Appidge intercepts traffic per process at the system layer and routes it through <strong>the proxy you already run</strong> — transparent proxies and proxy chains included.',
      ctaDownload: 'Download free trial',
      ctaBuy: 'Buy a license',
      noteHtml:
        '<b>Free trial</b> · 14-day money-back guarantee · No bundled nodes — traffic exits through your own setup',
    },
    panel: {
      title: 'Appidge — Active Processes',
      live: 'LIVE',
      thProcess: 'Process',
      thDest: 'Destination',
      thRoute: 'Route',
      thTraffic: 'Traffic',
      badgeProxy: 'Proxied',
      badgeDirect: 'Direct',
      loopName: 'Your proxy client',
      loopDest: 'proxy egress',
      badgeLoop: '◌ Loopback excluded',
      rulesHead: 'Rules · newest first · latest wins',
      ruleProxy: 'proxy',
      ruleDirect: 'direct',
      stateLatest: 'in effect',
      stateOverridden: 'overridden',
      captionHtml:
        '<b>In the app, click any process</b> to flip its route — the new rule takes effect immediately and overrides the old one',
    },
    scenes: {
      eyebrow: 'Sound familiar?',
      h2: 'To a lot of software, proxy settings are just a suggestion',
      sub: 'Apps with their own network stacks, dev toolchains, and background daemons route around macOS proxy settings whenever they like. Appidge intercepts at the system layer — nothing gets around it.',
      hotTag: 'worst offenders',
      cards: [
        {
          title: 'AI clients & editors',
          hot: true,
          body: 'They ship their own networking — your proxy settings might as well not exist. Stuck logins, failed requests.',
          tools: ['Claude Desktop', 'ChatGPT App', 'Cursor'],
        },
        {
          title: 'Model & dataset downloads',
          hot: true,
          body: 'A dropped direct connection at 30 GB means starting over. Proxied, downloads saturate your bandwidth and finish in one go.',
          tools: ['Hugging Face', 'Ollama', 'conda'],
        },
        {
          title: 'Docker & containers',
          body: "The daemon ignores your shell's proxy variables. Pulling an image shouldn't take all afternoon.",
          tools: ['Docker Desktop', 'OrbStack', 'Colima'],
        },
        {
          title: 'Package managers',
          body: 'One proxy config for pip, another for npm, another for Cargo — half of them quietly break. One rule now covers all of it.',
          tools: ['pip', 'npm', 'Cargo', 'Go', 'Homebrew'],
        },
        {
          title: 'Terminal & CLI',
          body: 'git clone hangs — right, you never exported the proxy variables. Forget them for good.',
          tools: ['git', 'curl', 'ssh', 'gh'],
        },
        {
          title: 'Research tools',
          body: "Reference managers that won't sync, datasets that won't download. Point each process where it should go.",
          tools: ['Zotero', 'EndNote', 'dataset sync'],
        },
      ],
    },
    how: {
      eyebrow: 'How it works',
      h2: 'Intercept, decide, forward — in one place',
      sub: "Built on macOS Network Extension. Every connection passes through Appidge's rule engine, whether or not the app respects proxy settings.",
      steps: [
        {
          n: '01 · Intercept',
          title: 'Take over traffic per process',
          body: 'Intercepted at the system network layer. With a proxy configured, traffic goes through it by default — no per-app setup. Your proxy client is auto-excluded, so nothing loops back.',
        },
        {
          n: '02 · Decide',
          title: 'Write rules by destination',
          body: 'Send these domains through the proxy; keep intranet and registry mirrors direct. Upstream is whatever you run — transparent proxies, anonymous proxies, and chains included.',
        },
        {
          n: '03 · Forward',
          title: 'Click a process to reroute it',
          body: 'The activity view lists every intercepted process. Click one, change its route, done — new rules override old ones automatically.',
        },
      ],
    },
    compare: {
      eyebrow: 'Compare',
      h2: 'Three ways to get an app onto your proxy',
      thApproach: 'Approach',
      thCoverage: 'Covers apps that ignore system proxy',
      thGranularity: 'Per-process control',
      thCost: 'Cost of changing rules',
      rows: [
        {
          name: 'System proxy settings',
          coverage: 'Apps can simply ignore it',
          coverageMark: 'no',
          granularity: 'All or nothing',
          granularityMark: 'no',
          cost: 'Low, but coverage is spotty',
        },
        {
          name: 'Per-app configuration',
          coverage: 'Depends on each app',
          coverageMark: 'part',
          granularity: 'A different setup for every tool',
          granularityMark: 'part',
          cost: 'High — fragmented and fragile',
        },
        {
          name: 'Appidge, per process',
          coverage: 'Enforced at the system network layer',
          coverageMark: 'yes',
          granularity: 'Click a process, effective immediately',
          granularityMark: 'yes',
          cost: 'One rule set, latest wins',
          highlight: true,
        },
      ],
      noteHtml:
        '<strong>Coming from Proxifier?</strong> Same job — per-process forwarding — rebuilt for modern macOS. Download it and run them side by side.',
    },
    notvpn: {
      eyebrow: "Let's be clear",
      h2: 'Appidge is not a VPN',
      sub: 'A local utility that forwards process traffic to a proxy you already run. Your network exit is always your own.',
      points: [
        {
          sign: 'no',
          title: 'No nodes, none for sale',
          body: 'No servers, no endpoints, no traffic subscriptions of any kind.',
        },
        {
          sign: 'no',
          title: 'Your traffic never touches us',
          body: 'Forwarding happens entirely on your Mac — to your proxy, or straight out.',
        },
        {
          sign: 'yes',
          title: 'Process-level forwarding, nothing more',
          body: "No proxy configured? Appidge can't conjure a network path out of thin air.",
        },
      ],
    },
    cta: {
      eyebrow: 'Get started',
      h2: 'Put every process under your rules',
      sub: 'Install it, watch the stubborn apps connect, then decide.',
      ctaDownload: 'Download free trial',
      ctaBuy: 'See pricing',
    },
  },
};
