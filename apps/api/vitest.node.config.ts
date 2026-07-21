import { defineConfig } from "vitest/config";

// 契约测试：纯 Node 环境跑 ajv（openapi 3.1 = JSON Schema 2020-12）校验 facade fixtures。
// 不进 workers pool（workerd 不允许 ajv 的 new Function 代码生成）。
export default defineConfig({
  test: {
    name: "contract",
    include: ["test/contract.test.ts"],
    environment: "node",
  },
});
