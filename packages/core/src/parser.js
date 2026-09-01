import { isScalar, parseDocument, visit } from "yaml";

const MAX_BYTES = 1024 * 1024;
const MAX_DEPTH = 64;
const MAX_NODES = 100000;

function diagnostic(code, file, message, path = "") {
  return { code, severity: "error", file, path, message };
}

function validateJsonValue(value, file, path = "", state = { nodes: 0 }) {
  if (state.limitReached) return [];
  state.nodes += 1;
  if (state.nodes > MAX_NODES) {
    state.limitReached = true;
    return [diagnostic("HKT009", file, "YAML document exceeds the node limit.")];
  }
  if (path.split("/").length - 1 > MAX_DEPTH) {
    state.limitReached = true;
    return [diagnostic("HKT009", file, "YAML document exceeds the nesting limit.", path)];
  }
  if (value === null || typeof value === "string" || typeof value === "boolean") return [];
  if (typeof value === "number") {
    return Number.isFinite(value) && (!Number.isInteger(value) || Number.isSafeInteger(value))
      ? []
      : [diagnostic("HKT103", file, `Non-finite or unsafe number at ${path || "/"}.`, path)];
  }
  if (Array.isArray(value)) {
    return value.flatMap((item, index) => validateJsonValue(item, file, `${path}/${index}`, state));
  }
  if (typeof value === "object") {
    return Object.entries(value).flatMap(([key, item]) => validateJsonValue(item, file, `${path}/${key.replaceAll("~", "~0").replaceAll("/", "~1")}`, state));
  }
  return [diagnostic("HKT103", file, `Unsupported value at ${path || "/"}.`, path)];
}

export function parseYaml(bytes, file) {
  if (bytes.length > MAX_BYTES) return { value: null, diagnostics: [diagnostic("HKT009", file, "YAML document exceeds the size limit.")] };
  let source;
  try {
    source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return { value: null, diagnostics: [diagnostic("HKT002", file, "File is not valid UTF-8.")] };
  }

  const document = parseDocument(source, {
    version: "1.2",
    schema: "core",
    strict: true,
    uniqueKeys: true,
    merge: false,
    resolveKnownTags: false,
    customTags: [],
    logLevel: "error"
  });
  const parserIssues = [...document.errors, ...document.warnings];
  if (parserIssues.length > 0) {
    const diagnostics = parserIssues.map((issue) => {
      const code = issue.code === "DUPLICATE_KEY" ? "HKT004"
        : issue.code === "MULTIPLE_DOCS" ? "HKT007"
          : String(issue.code).includes("TAG") ? "HKT005"
            : String(issue.code).includes("ALIAS") ? "HKT006" : "HKT003";
      return diagnostic(code, file, code === "HKT004" ? "Duplicate YAML key." : "Invalid or unsupported YAML syntax.");
    });
    return { value: null, diagnostics };
  }

  let nonStringKey = false;
  let hasAlias = false;
  visit(document, {
    Pair(_key, pair) {
      if (!isScalar(pair.key) || typeof pair.key.value !== "string") nonStringKey = true;
    },
    Alias() { hasAlias = true; }
  });
  if (nonStringKey) return { value: null, diagnostics: [diagnostic("HKT008", file, "YAML mapping keys must be strings.")] };
  if (hasAlias) return { value: null, diagnostics: [diagnostic("HKT006", file, "YAML aliases are not supported.")] };

  try {
    const value = document.toJS({ mapAsMap: false, maxAliasCount: 0 });
    const diagnostics = validateJsonValue(value, file);
    return { value: diagnostics.length === 0 ? value : null, diagnostics };
  } catch {
    return { value: null, diagnostics: [diagnostic("HKT006", file, "Invalid YAML alias structure.")] };
  }
}
