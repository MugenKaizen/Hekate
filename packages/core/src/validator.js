import { readFileSync } from "node:fs";
import Ajv2020 from "ajv/dist/2020.js";

const schemasRoot = new URL("../schemas/", import.meta.url);
const schemas = Object.fromEntries(["config", "project", "lock", "manifest", "plan", "install-state", "journal", "prepared-transaction", "apply-state", "legacy-import", "migration-report"].map((name) => [
  name,
  JSON.parse(readFileSync(new URL(`${name}.schema.json`, schemasRoot), "utf8"))
]));
const ajv = new Ajv2020({ strict: true, allErrors: true, ownProperties: true, validateFormats: false });
for (const [name, schema] of Object.entries(schemas)) ajv.addSchema(schema, name);
const validators = Object.fromEntries(Object.keys(schemas).map((name) => [name, ajv.getSchema(name)]));

const keywordCodes = {
  additionalProperties: "HKT104",
  const: "HKT103",
  enum: "HKT103",
  minItems: "HKT103",
  minLength: "HKT103",
  pattern: "HKT103",
  propertyNames: "HKT103",
  required: "HKT101",
  type: "HKT102"
};

export function validateSchema(kind, value, file) {
  const validate = validators[kind];
  if (validate(value)) return [];
  return (validate.errors ?? []).map((error) => ({
    code: keywordCodes[error.keyword] ?? "HKT103",
    severity: "error",
    file,
    path: error.instancePath || "",
    message: `Schema validation failed at ${error.instancePath || "/"} (${error.keyword}).`
  })).sort((left, right) => `${left.path}:${left.code}`.localeCompare(`${right.path}:${right.code}`, "en"));
}
