/** 下载页文案。 */

export interface DownloadCopy {
  title: string;
  metaDescription: string;
  eyebrow: string;
  h1: string;
  intro: string;
  ctaDownload: string;
  ctaBuy: string;
  /** Clash 类客户端 TUN 冲突提示(CTA 下方的兼容性 callout)。 */
  tunNoticeTitle: string;
  tunNoticeBody: string;
  requirementsTitle: string;
  requirements: string[];
  installTitle: string;
  installSteps: string[];
  updatesTitle: string;
  updatesBody: string;
}

export const download: Record<'zh' | 'en', DownloadCopy> = {
  zh: {
    title: '下载',
    metaDescription:
      '下载 Appidge for macOS。下载和购买是两回事：先装上试用，确认解决了你的「不走代理」问题，再购买许可证解锁。',
    eyebrow: '下载',
    h1: '下载 Appidge',
    intro:
      'Appidge 是 macOS 应用。下载和购买是两回事：先装上试试，确认那些一直连不上的软件都通了，再买许可证解锁。',
    ctaDownload: '下载 App（macOS）',
    ctaBuy: '购买许可证',
    tunNoticeTitle: '正在使用 Clash 类代理客户端？',
    tunNoticeBody:
      '使用 Appidge 前，请先关闭客户端（如 Clash Party、Clash Verge、mihomo）的 TUN／虚拟网卡／增强模式，只保留本地监听端口（如 127.0.0.1:7890），再在 Appidge 里把它添加为上游代理。TUN 与 Appidge 都会整机接管流量，同时开启会相互冲突，可能导致断网；关闭 TUN 不影响节点与订阅正常使用。',
    requirementsTitle: '系统要求',
    requirements: [
      'macOS 桌面系统。',
      '首次启动需按系统提示批准网络扩展（Network Extension）与相关权限——批准之后 Appidge 才能接管进程网络。',
    ],
    installTitle: '安装步骤',
    installSteps: [
      '点击上方「下载 App」获取安装包。',
      '打开下载的镜像，把 Appidge 拖进「应用程序」。',
      '首次启动时按系统提示批准所需权限。',
      '已购买许可证的话，在 App 内粘贴密钥完成激活。',
    ],
    updatesTitle: '更新',
    updatesBody: '应用内置自动更新，会从官方更新源检查并安装新版本，不用手动重新下载。',
  },
  en: {
    title: 'Download',
    metaDescription:
      'Download Appidge for macOS. Download and purchase are separate steps: install the trial first, confirm it fixes the apps that ignore your proxy, then buy a license to unlock.',
    eyebrow: 'Download',
    h1: 'Download Appidge',
    intro:
      'Appidge is a macOS app. Download and purchase are separate steps: install it, see whether the apps that never connect finally do, then unlock it with a license.',
    ctaDownload: 'Download for macOS',
    ctaBuy: 'Buy a license',
    tunNoticeTitle: 'Using a Clash-style proxy client?',
    tunNoticeBody:
      'Before using Appidge, turn off the client’s TUN / virtual-interface / enhanced mode (Clash Party, Clash Verge, mihomo, etc.) and keep only its local listening port (e.g. 127.0.0.1:7890), then add it as an upstream proxy in Appidge. TUN and Appidge both take over traffic system-wide; running them together conflicts and can cut off networking. Turning TUN off does not affect your nodes or subscriptions.',
    requirementsTitle: 'System requirements',
    requirements: [
      'macOS (desktop).',
      'On first launch, approve the Network Extension and related permissions when prompted — Appidge can only intercept process traffic once approved.',
    ],
    installTitle: 'Installation',
    installSteps: [
      'Click “Download for macOS” above to get the installer.',
      'Open the disk image and drag Appidge into Applications.',
      'Approve the required permissions when prompted on first launch.',
      'Already have a license? Paste the key in the app to activate.',
    ],
    updatesTitle: 'Updates',
    updatesBody:
      'The app updates itself from the official update feed — no need to download new versions by hand.',
  },
};
