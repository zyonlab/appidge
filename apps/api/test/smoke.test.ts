import { describe, it, expect, beforeEach } from "vitest";
import { handleRequest } from "../src/index";
import { ctxWith, resetSchema } from "./helpers";

describe("smoke", () => {
  beforeEach(async () => {
    await resetSchema();
  });

  it("healthz returns ok + mockMode", async () => {
    const res = await handleRequest(new Request("https://api.appidge.com/healthz"), ctxWith());
    expect(res.status).toBe(200);
    const body = (await res.json()) as { status: string; mockMode: boolean };
    expect(body.status).toBe("ok");
    expect(body.mockMode).toBe(true);
  });

  it("D1 schema is applied", async () => {
    const { env } = await import("cloudflare:test");
    const r = await env.DB.prepare("SELECT count(*) as n FROM entitlements").first<{ n: number }>();
    expect(r?.n).toBe(0);
  });
});
