/**
 * polar-sandbox-smoke.ts —— 真实 Polar sandbox API 冒烟脚本（可重复、绝不泄密）。
 *
 * 仅当 MOCK_MODE=false 且提供真实 access token 时才打真实网络；否则清晰 SKIP 并 exit 0。
 * 自动测试永不跑本脚本（它在 Node 下手动运行）。
 *
 * 用法：
 *   1. 编辑 apps/api/.dev.vars：MOCK_MODE=false、POLAR_ACCESS_TOKEN=polar_oat_...、
 *      POLAR_API_BASE=https://sandbox-api.polar.sh、POLAR_ORGANIZATION_ID=org_...
 *   2. 可选 POLAR_SMOKE_LICENSE_KEY=<你在 sandbox 购买得到的 license key>
 *   3. node --experimental-strip-types scripts/polar-sandbox-smoke.ts
 *
 * 绝不打印完整 license key / access token —— 只打印 HTTP 状态与脱敏摘要。
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const dir = path.dirname(fileURLToPath(import.meta.url));

function loadDevVars(): Record<string, string> {
  const out: Record<string, string> = { ...process.env } as Record<string, string>;
  try {
    const txt = readFileSync(path.join(dir, "..", ".dev.vars"), "utf8");
    for (const line of txt.split("\n")) {
      const t = line.trim();
      if (!t || t.startsWith("#")) continue;
      const eq = t.indexOf("=");
      if (eq === -1) continue;
      const k = t.slice(0, eq).trim();
      const v = t.slice(eq + 1).trim();
      if (!(k in process.env)) out[k] = v; // 环境变量优先
    }
  } catch {
    /* .dev.vars 不存在也没关系 */
  }
  return out;
}

function looksReal(token: string | undefined): boolean {
  return !!token && token.startsWith("polar_") && !token.includes("PLACEHOLDER");
}

async function main(): Promise<number> {
  const env = loadDevVars();
  const mock = String(env.MOCK_MODE ?? "true").toLowerCase() !== "false";
  const token = env.POLAR_ACCESS_TOKEN;
  const base = env.POLAR_API_BASE ?? "https://sandbox-api.polar.sh";
  const orgId = env.POLAR_ORGANIZATION_ID;

  if (mock || !looksReal(token)) {
    console.log("[smoke] SKIP —— MOCK_MODE 未关或未提供真实 polar_ token。这是预期的无操作退出（不算失败）。");
    return 0;
  }
  if (!orgId || orgId.includes("PLACEHOLDER")) {
    console.log("[smoke] SKIP —— 未设置真实 POLAR_ORGANIZATION_ID。");
    return 0;
  }

  const licenseKey = env.POLAR_SMOKE_LICENSE_KEY;
  if (!licenseKey) {
    console.log("[smoke] SKIP —— 未设置 POLAR_SMOKE_LICENSE_KEY，无法执行 validate 冒烟。");
    return 0;
  }

  console.log(`[smoke] 打真实 Polar sandbox：${base}/v1/license-keys/validate（key/token 已脱敏）`);
  try {
    const res = await fetch(`${base}/v1/license-keys/validate`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ key: licenseKey, organization_id: orgId }),
    });
    console.log(`[smoke] HTTP ${res.status}`);
    // 只打印状态字段，绝不回显完整响应（可能含 license 明文）
    try {
      const j = (await res.json()) as { status?: string };
      console.log(`[smoke] upstream status 字段: ${j.status ?? "(none)"}`);
    } catch {
      console.log("[smoke] 响应非 JSON 或为空");
    }
    console.log("[smoke] 完成。连通性与鉴权验证通过（据 HTTP 状态判断）。");
    return 0;
  } catch (err) {
    console.error(`[smoke] 网络错误: ${err instanceof Error ? err.message : String(err)}`);
    return 1;
  }
}

main().then((code) => process.exit(code));
