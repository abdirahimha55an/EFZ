// bundles the REAL dialog (from the repo, read-only) with ONLY the database module swapped for the stub
import { build } from 'esbuild';
import path from 'node:path';
import fs from 'node:fs';
const REPO = process.argv[2];
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const exts = ['.ts', '.tsx', '/index.ts', '/index.tsx'];
const resolveAt = (base) => { for (const e of ['', ...exts]) { const f = base + e; if (fs.existsSync(f) && fs.statSync(f).isFile()) return f; } return null; };
await build({
  entryPoints: [path.join(here, 'entry.jsx')], bundle: true, outfile: path.join(here, 'bundle.js'), format: 'iife', platform: 'browser', jsx: 'automatic', target: 'es2022',
  nodePaths: [path.join(REPO, 'node_modules')], logLevel: 'warning', define: { 'process.env.NODE_ENV': '"development"' },
  plugins: [{
    name: 'alias-at',
    setup(b) {
      b.onResolve({ filter: /^@\// }, (a) => {
        const rel = a.path.slice(2);
        if (rel === 'lib/supabase/db') return { path: path.join(here, 'stubdb.js') };
        const f = resolveAt(path.join(REPO, rel));
        if (!f) return { errors: [{ text: 'cannot resolve ' + a.path }] };
        return { path: f };
      });
    },
  }],
});
console.log('bundled');
