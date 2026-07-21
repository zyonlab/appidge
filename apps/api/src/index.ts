// Appidge license facade Worker —— module Worker，原生 fetch 路由（无框架）。
// 公开路由仅：GET /healthz、POST /v1/licenses/{activate,validate,deactivate}、POST /v1/webhooks/creem。
import type { Env } from "./env";
import { isMockMode, intVar } from "./env";
import { buildContext, type AppContext } from "./context";
import { ApiError } from "./errors";
import { json, errorResponse, fromApiError } from "./responses";
import { readJsonBody, parseJson } from "./validation";
import { clientKey } from "./ratelimit";
import { handleActivate, handleValidate, handleDeactivate } from "./handlers/licenses";
import { handleWebhook } from "./handlers/webhook";

type LicenseHandler = (ctx: AppContext, body: unknown) => Promise<Response>;

const LICENSE_ROUTES: Record<string, LicenseHandler> = {
  "/v1/licenses/activate": handleActivate,
  "/v1/licenses/validate": handleValidate,
  "/v1/licenses/deactivate": handleDeactivate,
};

export async function handleRequest(req: Request, ctx: AppContext): Promise<Response> {
  const url = new URL(req.url);
  const path = url.pathname;

  // healthz
  if (path === "/healthz") {
    if (req.method !== "GET") return errorResponse("invalid_request", 405, "Method not allowed");
    return json({ status: "ok", mockMode: isMockMode(ctx.env) }, 200);
  }

  // license 路由
  const licenseHandler = LICENSE_ROUTES[path];
  if (licenseHandler) {
    if (req.method !== "POST") return errorResponse("invalid_request", 405, "Method not allowed");
    if (!ctx.rateLimiter.check(clientKey(req, path))) {
      return errorResponse("rate_limited", 429, "Too many requests");
    }
    try {
      const maxBytes = intVar(ctx.env.MAX_BODY_BYTES, 16384);
      const raw = await readJsonBody(req, maxBytes);
      const body = parseJson(raw.text);
      return await licenseHandler(ctx, body);
    } catch (err) {
      return handleError(ctx, err);
    }
  }

  // webhook
  if (path === "/v1/webhooks/creem") {
    if (req.method !== "POST") return errorResponse("invalid_request", 405, "Method not allowed");
    if (!ctx.rateLimiter.check(clientKey(req, path))) {
      return errorResponse("rate_limited", 429, "Too many requests");
    }
    try {
      return await handleWebhook(ctx, req);
    } catch (err) {
      return handleError(ctx, err);
    }
  }

  return errorResponse("invalid_request", 404, "Not found");
}

function handleError(ctx: AppContext, err: unknown): Response {
  if (err instanceof ApiError) {
    if (err.httpStatus >= 500) ctx.logger.error("request.error", { code: err.code });
    return fromApiError(err);
  }
  ctx.logger.error("request.unhandled", { error: err instanceof Error ? err.message : String(err) });
  return errorResponse("internal_error", 500, "Internal error");
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const ctx = buildContext(env);
    try {
      return await handleRequest(req, ctx);
    } catch (err) {
      return handleError(ctx, err);
    }
  },
} satisfies ExportedHandler<Env>;
