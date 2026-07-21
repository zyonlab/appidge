import type { Env } from "../src/env";

// cloudflare:test 的 ProvidedEnv = 我们的 Env + 测试注入的 DDL 数组。
declare module "cloudflare:test" {
  interface ProvidedEnv extends Env {
    TEST_DDL: string[];
  }
}
