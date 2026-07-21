import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { parse as parseYaml } from "yaml";
import Ajv2020 from "ajv/dist/2020";
import addFormats from "ajv-formats";

const dir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(dir, "..", "..", "..");
const contractsDir = path.join(repoRoot, "contracts");

function loadJson(rel: string): unknown {
  return JSON.parse(readFileSync(path.join(contractsDir, rel), "utf8"));
}

const openapi = parseYaml(readFileSync(path.join(contractsDir, "licensing.openapi.yaml"), "utf8")) as {
  components: { schemas: Record<string, { enum?: string[] }> };
};

const ajv = new Ajv2020({ strict: false, validateSchema: false, allErrors: true });
addFormats(ajv);
ajv.addSchema(openapi, "oa");

function validator(schemaName: string) {
  return ajv.compile({ $ref: `oa#/components/schemas/${schemaName}` });
}

describe("facade fixtures conform to licensing.openapi.yaml", () => {
  const licenseState = validator("LicenseState");
  const errorSchema = validator("Error");
  const deactivate = validator("DeactivateResponse");

  it("activate.success.response is a valid LicenseState", () => {
    const fx = loadJson("fixtures/facade/activate.success.json") as { response: unknown };
    expect(licenseState(fx.response), JSON.stringify(licenseState.errors)).toBe(true);
  });

  it("validate.revoked.response is a valid LicenseState", () => {
    const fx = loadJson("fixtures/facade/validate.revoked.json") as { response: unknown };
    expect(licenseState(fx.response), JSON.stringify(licenseState.errors)).toBe(true);
  });

  it("error.activation_limit.response is a valid Error", () => {
    const fx = loadJson("fixtures/facade/error.activation_limit.json") as { response: unknown };
    expect(errorSchema(fx.response), JSON.stringify(errorSchema.errors)).toBe(true);
  });

  it("DeactivateResponse sample is valid", () => {
    expect(deactivate({ status: "deactivated" })).toBe(true);
    expect(deactivate({ status: "wrong" })).toBe(false);
  });

  it("validator rejects an invalid LicenseState (sanity)", () => {
    expect(licenseState({ status: "bogus" })).toBe(false);
  });
});

describe("error model parity", () => {
  it("openapi Error.enum exactly matches the facade error codes", () => {
    const enumFromContract = openapi.components.schemas.Error?.enum;
    // 实为 Error.properties.error.enum；从原始文档取。
    const raw = openapi as unknown as {
      components: { schemas: { Error: { properties: { error: { enum: string[] } } } } };
    };
    const codes = raw.components.schemas.Error.properties.error.enum;
    expect(enumFromContract).toBeUndefined(); // Error 顶层无 enum，防止读错位置
    expect(new Set(codes)).toEqual(
      new Set([
        "invalid_request",
        "invalid_license",
        "activation_limit",
        "expired",
        "revoked",
        "rate_limited",
        "upstream_unavailable",
        "internal_error",
      ]),
    );
  });
});
