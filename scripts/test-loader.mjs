// Minimal ESM resolve hook so Node's built-in test runner can import the app's TypeScript modules unchanged:
// "@/x" -> <repo>/x and extensionless relative imports -> .ts / .tsx / index.ts. Used only by `npm run test:hub`.
import { existsSync, statSync } from "node:fs";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tryExt = (base) => {
  for (const c of [base, `${base}.ts`, `${base}.tsx`, path.join(base, "index.ts")]) {
    if (path.extname(c) && existsSync(c) && statSync(c).isFile()) return c;
  }
  return null;
};

export async function resolve(specifier, context, next) {
  if (specifier.startsWith("@/")) {
    const f = tryExt(path.join(root, specifier.slice(2)));
    if (f) return next(pathToFileURL(f).href, context);
  } else if ((specifier.startsWith("./") || specifier.startsWith("../")) && context.parentURL?.startsWith("file:")) {
    const f = tryExt(path.resolve(path.dirname(fileURLToPath(context.parentURL)), specifier));
    if (f && !specifier.endsWith(path.extname(f))) return next(pathToFileURL(f).href, context);
  }
  return next(specifier, context);
}
