import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { defineWorkersConfig } from "@cloudflare/vitest-pool-workers/config";

const dir = path.dirname(fileURLToPath(import.meta.url));

// 从 migration 读取 DDL 作为测试 schema 的单一真相；按顺序应用所有迁移（0002 重建 entitlements），
// 剥掉注释后按 ';' 切成语句数组，交给测试 helper 逐条 prepare().run()
//（比 D1 .exec() 解析多语句更稳）。
const MIGRATIONS = ["0001_init.sql", "0002_polar.sql"];
const ddlStatements = MIGRATIONS.flatMap((file) =>
  readFileSync(path.join(dir, "migrations", file), "utf8")
    .split("\n")
    .filter((line) => !line.trim().startsWith("--"))
    .join("\n")
    .split(";")
    .map((s) => s.trim())
    .filter((s) => s.length > 0),
);

export default defineWorkersConfig({
  test: {
    // 契约测试用 ajv（workerd 禁用动态代码生成），单独放 node 项目：vitest.node.config.ts。
    include: ["test/**/*.test.ts"],
    exclude: ["test/contract.test.ts", "node_modules/**"],
    poolOptions: {
      workers: {
        wrangler: { configPath: "./wrangler.toml" },
        miniflare: {
          compatibilityFlags: ["nodejs_compat"],
          // 测试专用绑定：非秘密的 MOCK 值，保证测试无需真实 secret 即可运行。
          bindings: {
            MOCK_MODE: "true",
            POLAR_API_BASE: "https://sandbox-api.polar.sh",
            POLAR_ORGANIZATION_ID: "org_MOCK_appidge",
            POLAR_PRODUCT_ID: "prod_MOCK_appidge",
            POLAR_BENEFIT_ID: "ben_MOCK_appidge",
            RATE_LIMIT_MAX: "60",
            RATE_LIMIT_WINDOW_MS: "60000",
            MAX_BODY_BYTES: "16384",
            POLAR_ACCESS_TOKEN: "polar_oat_MOCK_key_do_not_use",
            POLAR_WEBHOOK_SECRET: "whsec_MOCK_secret_do_not_use",
            LICENSE_HMAC_PEPPER: "MOCK_pepper_do_not_use",
            TEST_DDL: ddlStatements,
          },
        },
      },
    },
  },
});
