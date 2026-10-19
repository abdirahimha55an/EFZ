// prints the JSON carried by 'T28RESULT:' in a failed (hence rolled back) Management API query
const fs = require('fs'); const raw = fs.readFileSync(process.argv[2], 'utf8');
let msg = raw;
try { const j = JSON.parse(raw); msg = j.error?.message ?? raw; const k = msg.indexOf('{'); if (k >= 0) { try { msg = JSON.parse(msg.slice(k)).message ?? msg; } catch {} } } catch {}
const i = msg.indexOf('T28RESULT:');
if (i < 0) { console.log('NO RESULT. Raw output:\n' + raw.slice(0, 2500)); process.exit(2); }
let body = msg.slice(i + 10); const c = body.indexOf('\nCONTEXT:'); if (c >= 0) body = body.slice(0, c);
try { const rows = JSON.parse(body); for (const r of rows) console.log(JSON.stringify(r)); } catch { console.log(body); }
