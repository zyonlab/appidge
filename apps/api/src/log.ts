// 脱敏日志：所有输出前先 redact，杜绝完整 license key / API key 进日志。
// 调用方本就不该把原始 secret 传进来；redact 是纵深防御的第二道。

export interface Redactor {
  secrets: string[]; // 需要整体屏蔽的原值（license key、api key、webhook secret、pepper）
}

export function redact(input: unknown, secrets: string[]): string {
  let s = typeof input === "string" ? input : safeStringify(input);
  for (const secret of secrets) {
    if (secret && secret.length >= 4) {
      s = s.split(secret).join("[REDACTED]");
    }
  }
  // 兜底：形似 creem key 的 token（creem_live_/creem_test_/whsec_）打码
  s = s.replace(/\b(creem_(?:live|test)_|whsec_)[A-Za-z0-9_-]{6,}\b/g, "$1[REDACTED]");
  return s;
}

function safeStringify(v: unknown): string {
  try {
    return JSON.stringify(v);
  } catch {
    return String(v);
  }
}

export interface Logger {
  info(event: string, fields?: Record<string, unknown>): void;
  warn(event: string, fields?: Record<string, unknown>): void;
  error(event: string, fields?: Record<string, unknown>): void;
}

export function createLogger(secrets: string[]): Logger {
  const emit = (level: "info" | "warn" | "error", event: string, fields?: Record<string, unknown>) => {
    const line = redact({ level, event, ...(fields ?? {}) }, secrets);
    if (level === "error") console.error(line);
    else if (level === "warn") console.warn(line);
    else console.log(line);
  };
  return {
    info: (e, f) => emit("info", e, f),
    warn: (e, f) => emit("warn", e, f),
    error: (e, f) => emit("error", e, f),
  };
}
