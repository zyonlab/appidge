#!/usr/bin/env bash
# scripts/qa-contract-check.sh — Agent F / Integration-QA
#
# 仓库根一个可发现的入口：校验 contracts/fixtures/facade/*.json 响应是否符合
# contracts/licensing.openapi.yaml。实际断言复用 apps/api 里已有的 ajv 契约测试
# （test/contract.test.ts），不引入新的 node 依赖、不重复实现 schema 逻辑。
#
# 用法：scripts/qa-contract-check.sh
# 依赖 pnpm + apps/api 的 devDeps（ajv / ajv-formats / yaml / vitest）。缺失则跳过（exit 0）。
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

command -v pnpm >/dev/null 2>&1 || { echo "SKIP: pnpm 不可用"; exit 0; }
[ -x "$ROOT/apps/api/node_modules/.bin/vitest" ] || { echo "SKIP: apps/api 依赖未安装（先 pnpm install）"; exit 0; }

echo "· 校验 facade fixtures ↔ licensing.openapi.yaml（复用 apps/api ajv 契约测试）…"
cd "$ROOT/apps/api" && exec pnpm run test:contract
