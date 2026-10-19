// Renders the REAL ConvertRequestDialog (bundled from the repo) in jsdom against a stubbed database and drives it like a user. Local only: no network.
import { JSDOM } from 'jsdom';
import fs from 'node:fs';
import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1'));
const bundle = fs.readFileSync(path.join(here, 'bundle.js'), 'utf8');

const results = [];
const check = (name, ok, detail = '') => { results.push({ name, ok: !!ok, detail }); console.log((ok ? 'PASS ' : 'FAIL ') + name + (ok ? '' : '  -> ' + detail)); };

const products = [
  { id: 'p-nexus', name: 'EFZ - Nexus', sellingPrice: 12, costPrice: null, stock: 62, isActive: true },
  { id: 'p-fire', name: 'EFZ - Fire Ball', sellingPrice: 12, costPrice: null, stock: 87, isActive: true },
];
const customers = [
  { id: 'cust-A', name: 'TEST Agreement A', status: 'active' }, { id: 'cust-B', name: 'TEST Design B', status: 'active' },
  { id: 'cust-C', name: 'TEST List C', status: 'active' }, { id: 'cust-D', name: 'TEST Pending D', status: 'active' },
];
const manager = { id: 'u-stg-manager', name: 'Manager', email: '', phone: '', avatar: '', role: 'Manager', status: 'active', commissionPercentage: 0, earnedCommissionTotal: 0, pendingCommissionTotal: 0, paidCommissionTotal: 0, permissions: [] };
const line = (n, productId, productName, quantity, extra = {}) => ({ lineNo: n, productId, productName, quantity, legacy: false, designName: '', ...extra });
const baseRequest = (lines, customerId) => ({ id: 'req-1', reference: 'REQ-TEST', customerName: 'TEST Visitor', phone: '0612800001', phoneCanonical: null, organization: '', deliveryLocation: 'x', visitorNotes: '', status: 'confirmed', convertedOrderId: null, handledBy: null, assignedTo: null, rejectedReason: null, statusChangedAt: null, createdAt: '2026-10-19', lines, ...(customerId ? { app: { customerId } } : {}) });

async function mount({ lines, customerId, setup }) {
  const dom = new JSDOM('<!doctype html><html><body><div id="root"></div></body></html>', { runScripts: 'outside-only', pretendToBeVisual: true, url: 'http://localhost/' });
  const w = dom.window; w.IS_REACT_ACT_ENVIRONMENT = true; w.MessageChannel = globalThis.MessageChannel; w.TextEncoder = globalThis.TextEncoder; w.TextDecoder = globalThis.TextDecoder; w.eval(bundle);
  const h = w.__h; h.stub.reset(); h.stub.products = products; h.stub.customers = customers;
  if (setup) setup(h.stub);
  const root = h.createRoot(w.document.getElementById('root'));
  await h.act(async () => { root.render(h.React.createElement(h.ConvertRequestDialog, { request: baseRequest(lines, customerId), profile: manager, staff: [], onClose: () => {}, onConverted: async () => {} })); });
  const doc = w.document;
  const ui = {
    w, doc, stub: h.stub, act: h.act,
    settle: async () => { for (let i = 0; i < 4; i++) await h.act(async () => { await new Promise((r) => setTimeout(r, 25)); }); },
    q: (s) => doc.querySelector(s), qa: (s) => [...doc.querySelectorAll(s)],
    text: (s) => (doc.querySelector(s)?.textContent ?? '').replace(/\s+/g, ' ').trim(),
    texts: (s) => [...doc.querySelectorAll(s)].map((e) => e.textContent.replace(/\s+/g, ' ').trim()),
    btn: (re) => [...doc.querySelectorAll('button')].find((b) => re.test(b.textContent.trim())),
    type: async (el, value) => { await h.act(async () => { Object.getOwnPropertyDescriptor(w.HTMLInputElement.prototype, 'value').set.call(el, value); el.dispatchEvent(new w.Event('input', { bubbles: true })); }); },
    click: async (el) => { await h.act(async () => { el.dispatchEvent(new w.MouseEvent('click', { bubbles: true })); }); },
    price: () => doc.querySelector('[data-testid=convert-price]'),
    create: () => [...doc.querySelectorAll('button')].find((b) => /^Create order/.test(b.textContent.trim())),
  };
  await ui.settle();
  return ui;
}

// ---- 1. list price
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 2)], customerId: 'cust-C' });
  check('1 list price: badge "List price", price 12, no override box, button "Create order" enabled',
    ui.text('[data-testid=convert-price-source]') === 'List price' && ui.price().value === '12' && !ui.q('[data-testid=override-reason]') && ui.create().textContent.trim() === 'Create order' && !ui.create().disabled,
    `${ui.text('[data-testid=convert-price-source]')} / ${ui.price().value} / ${ui.create().textContent}`);
  await ui.click(ui.create()); await ui.settle();
  const sent = ui.stub.converted[0]?.input;
  check('1 list price: the payload sends NO price (the database decides), customer C', sent && JSON.stringify(sent.lines) === JSON.stringify([{ productId: 'p-nexus', quantity: 2 }]) && sent.customer.customerId === 'cust-C' && sent.priceOverrideReason === undefined, JSON.stringify(sent));
  check('1 list price: success screen "Order ORD-STUB-1 created"', /Order ORD-STUB-1 created/.test(ui.doc.body.textContent), '');
}
// ---- 1b. new customer: no lookup is made, list price shown
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 1)], customerId: null });
  const radio = ui.qa('input[type=radio]').find((r) => /New customer/.test(r.closest('label')?.textContent ?? ''));
  await ui.click(radio); await ui.settle();
  check('1b new customer: list price shown without any price lookup', ui.text('[data-testid=convert-price-source]') === 'List price' && ui.price().value === '12' && ui.stub.lookups.length === 0, `${ui.price().value} lookups=${ui.stub.lookups.length}`);
}
// ---- 2a. product agreement
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 3)], customerId: 'cust-A', setup: (s) => s.answers.set('cust-A|p-nexus|', { source: 'agreement', price: 10, listPrice: 12, reason: null }) });
  check('2a product agreement: badge "Agreed price", price 10', ui.text('[data-testid=convert-price-source]') === 'Agreed price' && ui.price().value === '10', ui.price().value);
  await ui.click(ui.create()); await ui.settle();
  check('2a product agreement: payload sends no price (agreed price omitted)', JSON.stringify(ui.stub.converted[0]?.input.lines) === JSON.stringify([{ productId: 'p-nexus', quantity: 3 }]), JSON.stringify(ui.stub.converted[0]?.input.lines));
}
// ---- 2b. design agreement
{
  const ui = await mount({ lines: [line(1, 'p-fire', 'EFZ - Fire Ball', 1, { designName: 'E2E Red Design', designId: 'd-red' })], customerId: 'cust-B', setup: (s) => s.answers.set('cust-B|p-fire|E2E Red Design', { source: 'agreement', price: 9.5, listPrice: 12, reason: null }) });
  check('2b design agreement: chip "Design: E2E Red Design", badge "Agreed price", price 9.5', ui.text('[data-testid=convert-design]') === 'Design: E2E Red Design' && ui.text('[data-testid=convert-price-source]') === 'Agreed price' && ui.price().value === '9.5', `${ui.text('[data-testid=convert-design]')} / ${ui.price().value}`);
  check('2b the price lookup was asked WITH the design name', ui.stub.lookups.includes('cust-B|p-fire|E2E Red Design'), ui.stub.lookups.join(','));
  await ui.click(ui.create()); await ui.settle();
  check('2b payload carries the design id (not the name), and no price', JSON.stringify(ui.stub.converted[0]?.input.lines) === JSON.stringify([{ productId: 'p-fire', quantity: 1, designId: 'd-red' }]), JSON.stringify(ui.stub.converted[0]?.input.lines));
}
// ---- 3. failed lookup + Retry
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 2)], customerId: 'cust-C', setup: (s) => { s.failLookups = true; } });
  check('3 failed lookup: red message "We could not check this customer\'s price... press Retry.", Retry button shown', /We could not check this customer's price for this product\. Nothing was assumed - press Retry\./.test(ui.text('[data-testid=convert-line-blocked]')) && !!ui.q('[data-testid=convert-retry]'), ui.text('[data-testid=convert-line-blocked]'));
  check('3 failed lookup: the price box is EMPTY and disabled (no fallback price) and Create is disabled', ui.price().value === '' && ui.price().disabled && ui.create().disabled, `value="${ui.price().value}" disabled=${ui.price().disabled} createDisabled=${ui.create().disabled}`);
  await ui.click(ui.create()); await ui.settle();
  check('3 failed lookup: clicking the disabled Create button submits nothing', ui.stub.converted.length === 0, String(ui.stub.converted.length));
  ui.stub.failLookups = false; await ui.click(ui.q('[data-testid=convert-retry]')); await ui.settle();
  check('3 Retry: the lookup is asked again, the badge appears, the price fills in, Create is enabled', ui.text('[data-testid=convert-price-source]') === 'List price' && ui.price().value === '12' && !ui.create().disabled && !ui.q('[data-testid=convert-retry]'), `${ui.text('[data-testid=convert-price-source]')} ${ui.price().value} createDisabled=${ui.create().disabled}`);
}
// ---- 3b. malformed lookup answer is treated as a failure too
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 2)], customerId: 'cust-C', setup: (s) => { s.malformedLookups = true; } });
  check('3b malformed answer (price "ten"): treated as a failed lookup, nothing assumed, Create disabled', !!ui.q('[data-testid=convert-retry]') && ui.price().value === '' && ui.create().disabled, `retry=${!!ui.q('[data-testid=convert-retry]')} value="${ui.price().value}"`);
}
// ---- 4. review-required blocking
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 1)], customerId: 'cust-D', setup: (s) => s.answers.set('cust-D|p-nexus|', { source: 'review', price: null, listPrice: 12, reason: 'an agreement is waiting to be verified' }) });
  check('4 review-required: red "needs to be confirmed first (an agreement is waiting to be verified)"', /needs to be confirmed first \(an agreement is waiting to be verified\)/.test(ui.text('[data-testid=convert-line-blocked]')), ui.text('[data-testid=convert-line-blocked]'));
  check('4 review-required: price box disabled and empty, Create disabled, no Retry (this is not a failure)', ui.price().disabled && ui.price().value === '' && ui.create().disabled && !ui.q('[data-testid=convert-retry]'), '');
}
// ---- 5. override summary + reason validation
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 3)], customerId: 'cust-A', setup: (s) => s.answers.set('cust-A|p-nexus|', { source: 'agreement', price: 10, listPrice: 12, reason: null }) });
  await ui.type(ui.price(), '8'); await ui.settle();
  check('5 override: badge "Price changed (agreed $10.00)"', ui.text('[data-testid=convert-price-source]') === 'Price changed (agreed $10.00)', ui.text('[data-testid=convert-price-source]'));
  const row = ui.texts('[data-testid=override-summary] tbody tr')[0] ?? '';
  check('5 override summary shows product, qty 3, agreed $10.00, proposed $8.00 and the difference -$6.00 (-$2.00 each)', row === 'EFZ - Nexus3$10.00$8.00-$6.00 (-$2.00 each)', row);
  check('5 override: the button reads "Create order with price override" and is DISABLED without a reason', ui.create().textContent.trim() === 'Create order with price override' && ui.create().disabled, ui.create().textContent);
  const reason = ui.q('[aria-label="Price override reason"]');
  await ui.type(reason, 'too short'); await ui.settle();
  check('5 a 9-character reason keeps it disabled', ui.create().disabled, '');
  await ui.type(reason, '          '); await ui.settle();
  check('5 a blank (spaces only) reason keeps it disabled', ui.create().disabled, '');
  await ui.type(reason, 'Owner approved one-off price'); await ui.settle();
  check('5 a 10+ character reason enables it', !ui.create().disabled, '');
  await ui.click(ui.create()); await ui.settle();
  const sent = ui.stub.converted[0]?.input;
  check('5 payload: the changed price 8 is sent, with the reason', sent && JSON.stringify(sent.lines) === JSON.stringify([{ productId: 'p-nexus', quantity: 3, actualUnitPrice: 8 }]) && sent.priceOverrideReason === 'Owner approved one-off price', JSON.stringify(sent));
}
// ---- 5b. "Use the agreed price" undoes the override
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 3)], customerId: 'cust-A', setup: (s) => s.answers.set('cust-A|p-nexus|', { source: 'agreement', price: 10, listPrice: 12, reason: null }) });
  await ui.type(ui.price(), '8'); await ui.settle();
  await ui.click(ui.btn(/Use the agreed price/)); await ui.settle();
  check('5b "Use the agreed price" restores 10, removes the override box, button back to "Create order" and enabled', ui.price().value === '10' && !ui.q('[data-testid=override-reason]') && ui.create().textContent.trim() === 'Create order' && !ui.create().disabled, `${ui.price().value} ${ui.create().textContent}`);
  await ui.type(ui.price(), '10.00'); await ui.settle();
  check('5b typing the SAME price as agreed is not an override (no box, no price sent)', !ui.q('[data-testid=override-reason]'), '');
}
// ---- 6. several designs of one product
{
  const ui = await mount({ lines: [line(1, 'p-fire', 'EFZ - Fire Ball', 1, { designName: 'E2E Red Design', designId: 'd-red' }), line(2, 'p-fire', 'EFZ - Fire Ball', 1, { designName: 'TEST-28 Blue', designId: 'd-blue' })], customerId: 'cust-B',
    setup: (s) => { s.answers.set('cust-B|p-fire|E2E Red Design', { source: 'agreement', price: 9, listPrice: 12, reason: null }); s.answers.set('cust-B|p-fire|TEST-28 Blue', { source: 'agreement', price: 11, listPrice: 12, reason: null }); } });
  const chips = ui.texts('[data-testid=convert-design]'); const prices = ui.qa('[data-testid=convert-price]').map((p) => p.value);
  check('6 two designs of the same product: two lines, each with its own design chip and its own price (9 and 11)', chips.join('|') === 'Design: E2E Red Design|Design: TEST-28 Blue' && prices.join('|') === '9|11', `${chips} ${prices}`);
  check('6 no duplicate-line error: Create is enabled', !ui.create().disabled, '');
  await ui.click(ui.create()); await ui.settle();
  check('6 payload: two lines, one per design id, no prices', JSON.stringify(ui.stub.converted[0]?.input.lines) === JSON.stringify([{ productId: 'p-fire', quantity: 1, designId: 'd-red' }, { productId: 'p-fire', quantity: 1, designId: 'd-blue' }]), JSON.stringify(ui.stub.converted[0]?.input.lines));
}
// ---- 7. customer switch after typing a price
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 3)], customerId: 'cust-A', setup: (s) => s.answers.set('cust-A|p-nexus|', { source: 'agreement', price: 10, listPrice: 12, reason: null }) });
  await ui.type(ui.price(), '8'); await ui.settle();
  check('7 precondition: a typed 8 shows the override box for customer A', !!ui.q('[data-testid=override-reason]'), '');
  await ui.type(ui.q('[aria-label="Search customers"]'), 'TEST List'); await ui.settle();
  const pick = ui.qa('button').find((b) => /cust-C/.test(b.textContent));
  await ui.click(pick); await ui.settle();
  check('7 after switching to customer C: the typed price is cleared and the price is re-asked (list 12), no override box, no "Price changed"',
    ui.price().value === '12' && ui.text('[data-testid=convert-price-source]') === 'List price' && !ui.q('[data-testid=override-reason]') && ui.stub.lookups.includes('cust-C|p-nexus|'), `${ui.price().value} ${ui.text('[data-testid=convert-price-source]')} lookups=${ui.stub.lookups.join(',')}`);
  await ui.click(ui.create()); await ui.settle();
  const sent = ui.stub.converted[0]?.input;
  check('7 and what is sent is for customer C with NO price and NO override reason', sent && sent.customer.customerId === 'cust-C' && JSON.stringify(sent.lines) === JSON.stringify([{ productId: 'p-nexus', quantity: 3 }]) && sent.priceOverrideReason === undefined, JSON.stringify(sent));
}
// ---- 8. the database refuses a duplicate conversion: the dialog shows it and writes nothing
{
  const ui = await mount({ lines: [line(1, 'p-nexus', 'EFZ - Nexus', 1)], customerId: 'cust-C', setup: (s) => { s.convertError = new Error('Website request REQ-TEST was already converted to order ORD-9'); } });
  await ui.click(ui.create()); await ui.settle();
  const body = ui.doc.body.textContent;
  check('8 duplicate conversion refused by the database: the error is shown with "Nothing was created; the request is still confirmed.", no success screen', /already converted to order ORD-9/.test(body) && /Nothing was created; the request is still confirmed\./.test(body) && !/created\b.*ORD-STUB/.test(body) && !/Order ORD-STUB-1 created/.test(body), body.slice(0, 200));
}

const failed = results.filter((r) => !r.ok);
console.log(`\n${results.length - failed.length} passed, ${failed.length} failed`);
process.exit(failed.length ? 1 : 0);
