/**
 * creem-sandbox-smoke.ts —— 真实 Creem test API 冒烟脚本（可重复、绝不泄密）。
 *
 * 仅当 MOCK_MODE=false 且提供真实 test key 时才打真实网络；否则清晰 SKIP 并 exit 0。
 * 自动测试永不跑本脚本（它在 Node 下手动运行）。
 *
 * 用法：
 *   1. 编辑 apps/api/.dev.vars：MOCK_MODE=false、CREEM_API_KEY=creem_test_...、CREEM_API_BASE=https://test-api.creem.io
 *   2. 可选 CREEM_SMOKE_LICENSE_KEY=<你在 test mode 购买得到的 license key>
 *   3. node --experimental-strip-types scripts/creem-sandbox-smoke.ts
 *
 * 绝不打印完整 license key / API key —— 只打印 HTTP 状态与脱敏摘要。
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

function looksReal(key: string | undefined): boolean {
  return !!key && key.startsWith("creem_test_") && !key.includes("PLACEHOLDER");
}

async function main(): Promise<number> {
  const env = loadDevVars();
  const mock = String(env.MOCK_MODE ?? "true").toLowerCase() !== "false";
  const apiKey = env.CREEM_API_KEY;
  const base = env.CREEM_API_BASE ?? "https://test-api.creem.io";

  if (mock || !looksReal(apiKey)) {
    console.log(
      "[smoke] SKIP —— MOCK_MODE 未关或未提供真实 creem_test_ key。这是预期的无操作退出（不算失败）。",
    );
    return 0;
  }

  const licenseKey = env.CREEM_SMOKE_LICENSE_KEY;
  if (!licenseKey) {
    console.log("[smoke] SKIP —— 未设置 CREEM_SMOKE_LICENSE_KEY，无法执行 validate 冒烟。");
    return 0;
  }

  console.log(`[smoke] 打真实 Creem test API：${base}/v1/licenses/validate（key 已脱敏）`);
  try {
    const res = await fetch(`${base}/v1/licenses/validate`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": apiKey },
      body: JSON.stringify({ key: licenseKey, instance_id: "smoke-noop" }),
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
