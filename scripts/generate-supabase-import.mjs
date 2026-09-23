#!/usr/bin/env node
/**
 * Converts an EFZ localStorage backup JSON into a single idempotent SQL file
 * that can be pasted into the Supabase SQL Editor.
 *
 *   node scripts/generate-supabase-import.mjs                       # newest backup
 *   node scripts/generate-supabase-import.mjs Backup/efz_full_backup_2026-09-09.json
 *   node scripts/generate-supabase-import.mjs <input> <output.sql>
 *
 * What it deliberately does NOT emit:
 *   - passwords. Credentials belong to Supabase Auth; the script prints the
 *     list of accounts you still need to create there.
 *   - orders.total / cost / gross_profit / amount_paid / outstanding_balance.
 *     Those are recomputed by the triggers in 02_functions.sql from the rows
 *     this file inserts, which is also a free integrity check on the old data.
 *   - product stock deductions. Product stock in the backup is already net of
 *     every past sale, so the historical orders must not deduct it again.
 */

import { readFileSync, writeFileSync, readdirSync } from "node:fs";
import { join, resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");

// ---------------------------------------------------------------------------
// SQL literal helpers
// ---------------------------------------------------------------------------

const sqlStr = (value) => {
  if (value === null || value === undefined) return "null";
  return `'${String(value).replace(/'/g, "''")}'`;
};

const sqlNum = (value, fallback = 0) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? String(parsed) : String(fallback);
};

const sqlInt = (value, fallback = 0) => {
  const parsed = Math.round(Number(value));
  return Number.isFinite(parsed) ? String(parsed) : String(fallback);
};

const sqlBool = (value) => (value ? "true" : "false");

const sqlDate = (value) => {
  if (!value) return "null";
  const raw = String(value).slice(0, 10);
  return /^\d{4}-\d{2}-\d{2}$/.test(raw) ? `'${raw}'::date` : "null";
};

const sqlTimestamp = (value) => {
  if (!value) return "null";
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? "null" : `'${parsed.toISOString()}'::timestamptz`;
};

const sqlJson = (value) => {
  if (value === null || value === undefined) return `'{}'::jsonb`;
  return `${sqlStr(JSON.stringify(value))}::jsonb`;
};

const sqlTextArray = (values) => {
  if (!Array.isArray(values) || values.length === 0) return `'{}'::text[]`;
  return `array[${values.map(sqlStr).join(", ")}]::text[]`;
};

// ---------------------------------------------------------------------------
// Value normalisation (mirrors the repair logic in lib/services/*)
// ---------------------------------------------------------------------------

const VALID_ROLES = new Set([
  "Super Admin", "Manager", "Marketing Officer", "Inventory Staff", "Delivery Staff",
]);
const VALID_CATEGORIES = new Set(["Football", "Futsal", "Accessories"]);
const VALID_ORDER_STATUSES = new Set([
  "pending", "confirmed", "processing", "delivered", "cancelled",
]);
const VALID_PAYMENT_STATUSES = new Set([
  "unpaid", "partial", "paid", "refunded", "credit",
]);
const VALID_MOVEMENT_TYPES = new Set([
  "sale", "manual_adjustment", "correction", "return", "import",
]);
const VALID_SEVERITIES = new Set(["INFO", "WARNING", "ERROR", "CRITICAL"]);
const VALID_LOG_CATEGORIES = new Set([
  "SECURITY", "FINANCIAL", "INVENTORY", "CUSTOMER",
  "SYSTEM", "AUTH", "STORAGE", "ORDER", "PRODUCT",
]);
const VALID_NOTIFICATION_TYPES = new Set(["stock", "order", "system"]);

/** Matches migrateStatus() in lib/services/order.service.ts. */
const normalizeOrderStatus = (status) => {
  const value = String(status || "pending").toLowerCase();
  if (VALID_ORDER_STATUSES.has(value)) return value;
  if (value === "paid") return "confirmed";
  if (value === "successfully delivered" || value === "completed") return "delivered";
  return "pending";
};

// ---------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------

const pickNewestBackup = () => {
  const dir = join(ROOT, "Backup");
  const candidates = readdirSync(dir)
    .filter((name) => name.startsWith("efz_full_backup_") && name.endsWith(".json"))
    .sort();
  if (candidates.length === 0) {
    throw new Error("No efz_full_backup_*.json found in Backup/");
  }
  return join(dir, candidates[candidates.length - 1]);
};

const inputPath = process.argv[2] ? resolve(process.argv[2]) : pickNewestBackup();
const outputPath = process.argv[3]
  ? resolve(process.argv[3])
  : join(ROOT, "supabase", "06_data_import.sql");

const backup = JSON.parse(readFileSync(inputPath, "utf8"));
const payload = backup.data ?? backup;

const readCollection = (key, fallback) => {
  const raw = payload[key];
  if (raw === undefined || raw === null) return fallback;
  try {
    return typeof raw === "string" ? JSON.parse(raw) : raw;
  } catch {
    return fallback;
  }
};

const users = readCollection("efz_mock_users", []);
const customers = readCollection("efz_mock_customers", []);
const products = readCollection("efz_mock_products", []);
const orders = readCollection("efz_mock_orders", []);
const movements = readCollection("efz_stock_movements", []);
const logs = readCollection("efz_system_logs", []);
const notifications = readCollection("efz_mock_notifications", []);
const settings = readCollection("efz_mock_settings", null);

// Reference sets, so a dangling foreign key becomes NULL instead of a failed import.
const userIds = new Set(users.map((u) => u.id));
const customerIds = new Set(customers.map((c) => c.id));
const productIds = new Set(products.map((p) => p.id));

const ref = (id, pool) => (id && pool.has(id) ? sqlStr(id) : "null");

const warnings = [];
const out = [];
const w = (line = "") => out.push(line);

// ---------------------------------------------------------------------------
// Header
// ---------------------------------------------------------------------------

w("-- ============================================================================");
w("-- EFZ - Supabase data import");
w(`-- Generated : ${new Date().toISOString()}`);
w(`-- Source    : ${inputPath.replace(ROOT, ".").replace(/\\/g, "/")}`);
w(`-- Snapshot  : ${backup.timestamp ?? "unknown"}`);
w("-- ----------------------------------------------------------------------------");
w("-- Run AFTER 01_schema.sql .. 05_seed.sql. Safe to re-run: every statement is");
w("-- an upsert keyed on the original localStorage id.");
w("-- ============================================================================");
w();
w("begin;");
w();

// ---------------------------------------------------------------------------
// 1. Profiles
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w(`-- 1. PROFILES (${users.length})`);
w("-- Passwords are intentionally absent. Create the matching Supabase Auth users");
w("-- with the same email and the trigger in 02_functions.sql links them here.");
w("-- ---------------------------------------------------------------------------");
w();

for (const user of users) {
  const role = VALID_ROLES.has(user.role) ? user.role : "Marketing Officer";
  if (!VALID_ROLES.has(user.role)) {
    warnings.push(`user ${user.id}: unknown role "${user.role}" -> Marketing Officer`);
  }
  if (user.password) {
    warnings.push(`user ${user.id} (${user.email}): password dropped, create the Auth user manually`);
  }

  w("insert into public.profiles (id, name, email, phone, avatar, role, status, commission_percentage)");
  w(`values (${sqlStr(user.id)}, ${sqlStr(user.name)}, ${sqlStr(user.email)}, ` +
    `${sqlStr(user.phone ?? "")}, ${sqlStr(user.avatar ?? "")}, ` +
    `${sqlStr(role)}::public.user_role, ` +
    `${sqlStr(user.status === "inactive" ? "inactive" : "active")}::public.user_status, ` +
    `${sqlNum(user.commissionPercentage)})`);
  w("on conflict (id) do update set");
  w("  name = excluded.name, email = excluded.email, phone = excluded.phone,");
  w("  avatar = excluded.avatar, role = excluded.role, status = excluded.status,");
  w("  commission_percentage = excluded.commission_percentage;");
  w();
}

// ---------------------------------------------------------------------------
// 2. User permissions
// ---------------------------------------------------------------------------

const permissionRows = [];
for (const user of users) {
  for (const code of user.permissions ?? []) {
    permissionRows.push(`  (${sqlStr(user.id)}, ${sqlStr(code)})`);
  }
}

w("-- ---------------------------------------------------------------------------");
w(`-- 2. USER PERMISSIONS (${permissionRows.length})`);
w("-- Unknown codes are dropped by the join against public.permissions.");
w("-- ---------------------------------------------------------------------------");
w();

if (permissionRows.length > 0) {
  w("insert into public.user_permissions (user_id, permission_code)");
  w("select v.user_id, v.code");
  w("from (values");
  w(permissionRows.join(",\n"));
  w(") as v(user_id, code)");
  w("join public.permissions p on p.code = v.code");
  w("on conflict do nothing;");
} else {
  w("-- none in the backup");
}
w();

// ---------------------------------------------------------------------------
// 3. Customers
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w(`-- 3. CUSTOMERS (${customers.length})`);
w("-- ---------------------------------------------------------------------------");
w();

for (const customer of customers) {
  const archived = Boolean(customer.isArchived) || customer.status === "archived";
  const registeredOn = sqlDate(customer.date);

  w("insert into public.customers (id, name, email, phone, registered_by, marketing_officer_id, registered_on, notes, status)");
  w(`values (${sqlStr(customer.id)}, ${sqlStr(customer.name)}, ${sqlStr(customer.email ?? "")}, ` +
    `${sqlStr(customer.phone ?? "")}, ${ref(customer.registeredBy, userIds)}, ` +
    `${ref(customer.marketingOfficerId ?? customer.registeredBy, userIds)}, ` +
    `coalesce(${registeredOn}, current_date), ${sqlStr(customer.notes ?? "")}, ` +
    `${sqlStr(archived ? "archived" : "active")}::public.customer_status)`);
  w("on conflict (id) do update set");
  w("  name = excluded.name, email = excluded.email, phone = excluded.phone,");
  w("  registered_by = excluded.registered_by,");
  w("  marketing_officer_id = excluded.marketing_officer_id,");
  w("  registered_on = excluded.registered_on, notes = excluded.notes,");
  w("  status = excluded.status;");
  w();

  if (customer.registeredBy && !userIds.has(customer.registeredBy)) {
    warnings.push(`customer ${customer.id}: registeredBy "${customer.registeredBy}" not found -> NULL`);
  }
}

// ---------------------------------------------------------------------------
// 4. Products
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w(`-- 4. PRODUCTS (${products.length})`);
w("-- Stock is the CURRENT level, already net of every historical sale below.");
w("-- ---------------------------------------------------------------------------");
w();

for (const product of products) {
  const category = VALID_CATEGORIES.has(product.category) ? product.category : "Football";
  if (!VALID_CATEGORIES.has(product.category)) {
    warnings.push(`product ${product.id}: unknown category "${product.category}" -> Football`);
  }
  const selling = Number(product.sellingPrice ?? product.price ?? 0);

  w("insert into public.products (id, name, description, category, size, durability, surface_type,");
  w("                            is_wholesale, cost_price, selling_price, stock, low_stock_threshold, image_url)");
  w(`values (${sqlStr(product.id)}, ${sqlStr(product.name)}, ${sqlStr(product.description ?? "")}, ` +
    `${sqlStr(category)}::public.product_category, ${sqlStr(product.size ?? "")}, ` +
    `${sqlStr(product.durability ?? "")}, ${sqlStr(product.surfaceType ?? "")}, ` +
    `${sqlBool(product.isWholesale ?? true)}, ${sqlNum(product.costPrice)}, ${sqlNum(selling)}, ` +
    `${sqlInt(product.stock)}, ${sqlInt(product.lowStockThreshold, 50)}, ${sqlStr(product.imageUrl ?? "")})`);
  w("on conflict (id) do update set");
  w("  name = excluded.name, description = excluded.description, category = excluded.category,");
  w("  size = excluded.size, durability = excluded.durability, surface_type = excluded.surface_type,");
  w("  is_wholesale = excluded.is_wholesale, cost_price = excluded.cost_price,");
  w("  selling_price = excluded.selling_price, stock = excluded.stock,");
  w("  low_stock_threshold = excluded.low_stock_threshold, image_url = excluded.image_url;");
  w();
}

// ---------------------------------------------------------------------------
// 5. Orders, items, payments
// ---------------------------------------------------------------------------

let itemCount = 0;
let paymentCount = 0;
const seenItemIds = new Set();
const seenPaymentIds = new Set();

w("-- ---------------------------------------------------------------------------");
w(`-- 5. ORDERS (${orders.length}) with items and payments`);
w("-- total / cost / gross_profit / amount_paid / outstanding_balance are left to");
w("-- the triggers. If a computed total disagrees with the backup value, the");
w("-- verification block at the end of this file reports it.");
w("-- ---------------------------------------------------------------------------");
w();

for (const order of orders) {
  const status = normalizeOrderStatus(order.status);
  if (status !== String(order.status || "").toLowerCase()) {
    warnings.push(`order ${order.id}: status "${order.status}" migrated to "${status}"`);
  }

  const rawPaymentStatus = String(order.paymentStatus || "unpaid").toLowerCase();
  const paymentStatus = VALID_PAYMENT_STATUSES.has(rawPaymentStatus) ? rawPaymentStatus : "unpaid";

  if (order.customerId && !customerIds.has(order.customerId)) {
    warnings.push(`order ${order.id}: customerId "${order.customerId}" not found -> NULL`);
  }

  w(`-- Order ${order.id} | ${order.customer ?? ""} | backup total ${order.total ?? 0}`);
  w("insert into public.orders (id, customer_id, customer_name, phone, marketing_officer_id,");
  w("                          status, payment_status, order_type, order_date, delivery_notes,");
  w("                          commission_paid, legacy_order_ids, legacy_reference_id, created_at)");
  w(`values (${sqlStr(order.id)}, ${ref(order.customerId, customerIds)}, ` +
    `${sqlStr(order.customerName ?? order.customer ?? "")}, ` +
    `${sqlStr(order.customerPhone ?? order.phone ?? "")}, ` +
    `${ref(order.marketingOfficerId, userIds)}, ` +
    `${sqlStr(status)}::public.order_status, ` +
    `${sqlStr(paymentStatus)}::public.payment_status, ` +
    `${sqlStr(order.orderType === "trial" ? "trial" : "regular")}::public.order_type, ` +
    `coalesce(${sqlDate(order.date)}, current_date), ` +
    `${sqlStr(order.deliveryNotes ?? "")}, ${sqlBool(order.commissionPaid)}, ` +
    `${sqlTextArray(order.legacyOrderIds)}, ${sqlStr(order.legacyReferenceId ?? order.id)}, ` +
    `coalesce(${sqlTimestamp(order.createdAt)}, now()))`);
  w("on conflict (id) do update set");
  w("  customer_id = excluded.customer_id, customer_name = excluded.customer_name,");
  w("  phone = excluded.phone, marketing_officer_id = excluded.marketing_officer_id,");
  w("  status = excluded.status, order_type = excluded.order_type,");
  w("  order_date = excluded.order_date, delivery_notes = excluded.delivery_notes,");
  w("  commission_paid = excluded.commission_paid,");
  w("  legacy_order_ids = excluded.legacy_order_ids,");
  w("  legacy_reference_id = excluded.legacy_reference_id;");
  w();

  // Replace children rather than merge, so re-running never duplicates lines.
  w(`delete from public.order_items where order_id = ${sqlStr(order.id)};`);
  w(`delete from public.payments    where order_id = ${sqlStr(order.id)};`);
  w();

  const items = Array.isArray(order.items) ? order.items : [];
  items.forEach((item, index) => {
    let itemId = item.id || `itm-${order.id}-${index + 1}`;
    while (seenItemIds.has(itemId)) itemId = `${itemId}-${index + 1}`;
    seenItemIds.add(itemId);
    itemCount += 1;

    if (item.productId && !productIds.has(item.productId)) {
      warnings.push(`order ${order.id} item ${itemId}: productId "${item.productId}" not found -> NULL`);
    }

    const actual = Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0);
    const standard = Number(item.standardUnitPrice ?? item.price ?? item.actualUnitPrice ?? 0);
    const cost = Number(item.historicalUnitCost ?? item.costPrice ?? 0);

    w("insert into public.order_items (id, order_id, product_id, product_name, design_name, quantity,");
    w("                              standard_unit_price, actual_unit_price, historical_unit_cost) values");
    w(`  (${sqlStr(itemId)}, ${sqlStr(order.id)}, ${ref(item.productId, productIds)}, ` +
      `${sqlStr(item.productName ?? "Unknown Product")}, ` +
      `${sqlStr(item.designName ?? item.productName ?? "")}, ` +
      `${sqlInt(Math.max(1, Number(item.quantity) || 1), 1)}, ` +
      `${sqlNum(standard)}, ${sqlNum(actual)}, ${sqlNum(cost)});`);
  });
  if (items.length > 0) w();

  const payments = Array.isArray(order.payments) ? order.payments : [];
  payments.forEach((payment, index) => {
    let paymentId = payment.id || `pay-${order.id}-${index + 1}`;
    while (seenPaymentIds.has(paymentId)) paymentId = `${paymentId}-${index + 1}`;
    seenPaymentIds.add(paymentId);

    const amount = Number(payment.amount || 0);
    if (!(amount > 0)) {
      warnings.push(`order ${order.id} payment ${paymentId}: amount ${amount} skipped (must be > 0)`);
      return;
    }
    paymentCount += 1;

    w("insert into public.payments (id, order_id, amount, payment_date, payment_method, reference, notes, recorded_by) values");
    w(`  (${sqlStr(paymentId)}, ${sqlStr(order.id)}, ${sqlNum(amount)}, ` +
      `coalesce(${sqlDate(payment.paymentDate)}, current_date), ` +
      `${sqlStr(payment.paymentMethod || "Cash")}, ${sqlStr(payment.reference ?? "")}, ` +
      `${sqlStr(payment.notes ?? payment.note ?? "")}, ${ref(payment.recordedBy, userIds)});`);
  });
  if (payments.length > 0) w();
}

// A legacy order with no payment rows but a non-zero amountPaid would otherwise
// silently lose that money, so surface it rather than inventing a payment.
for (const order of orders) {
  const payments = Array.isArray(order.payments) ? order.payments : [];
  const recorded = payments.reduce((sum, p) => sum + Number(p.amount || 0), 0);
  const legacyPaid = Number(order.amountPaid || 0);
  if (payments.length === 0 && legacyPaid > 0) {
    warnings.push(
      `order ${order.id}: amountPaid ${legacyPaid} has no payment records - ` +
      `it will import as unpaid. Add a payment row manually if the cash was real.`
    );
  } else if (payments.length > 0 && Math.abs(recorded - legacyPaid) > 0.01) {
    warnings.push(
      `order ${order.id}: amountPaid ${legacyPaid} != sum of payments ${recorded}`
    );
  }
}

// ---------------------------------------------------------------------------
// 6. Stock movements
// ---------------------------------------------------------------------------

const importableMovements = movements.filter((movement) => {
  if (!productIds.has(movement.productId)) {
    warnings.push(`stock movement ${movement.id}: productId "${movement.productId}" not found - skipped`);
    return false;
  }
  return true;
});

w("-- ---------------------------------------------------------------------------");
w(`-- 6. STOCK MOVEMENTS (${importableMovements.length} of ${movements.length})`);
w("-- Historical ledger only. These do not change products.stock.");
w("-- ---------------------------------------------------------------------------");
w();

for (const movement of importableMovements) {
  const type = VALID_MOVEMENT_TYPES.has(movement.type) ? movement.type : "correction";

  w("insert into public.stock_movements (id, product_id, product_name, type, quantity_change, reason, created_by, created_at)");
  w(`values (${sqlStr(movement.id)}, ${sqlStr(movement.productId)}, ${sqlStr(movement.productName ?? "")}, ` +
    `${sqlStr(type)}::public.stock_movement_type, ${sqlInt(movement.quantityChange)}, ` +
    `${sqlStr(movement.reason ?? "")}, ${ref(movement.createdBy, userIds)}, ` +
    `coalesce(${sqlTimestamp(movement.timestamp)}, now()))`);
  w("on conflict (id) do nothing;");
  w();
}

// ---------------------------------------------------------------------------
// 7. System logs
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w(`-- 7. SYSTEM LOGS (${logs.length})`);
w("-- ---------------------------------------------------------------------------");
w();

for (const log of logs) {
  const severity = VALID_SEVERITIES.has(log.severity) ? log.severity : "INFO";
  const category = VALID_LOG_CATEGORIES.has(log.category) ? log.category : "SYSTEM";

  w("insert into public.system_logs (id, occurred_at, severity, category, message, user_id, username, target_id, metadata)");
  w(`values (${sqlStr(log.id)}, coalesce(${sqlTimestamp(log.timestamp)}, now()), ` +
    `${sqlStr(severity)}::public.log_severity, ${sqlStr(category)}::public.log_category, ` +
    `${sqlStr(log.message ?? "")}, ${ref(log.userId, userIds)}, ${sqlStr(log.username ?? "")}, ` +
    `${sqlStr(log.targetId ?? null)}, ${sqlJson(log.metadata)})`);
  w("on conflict (id) do nothing;");
  w();
}

// ---------------------------------------------------------------------------
// 8. Notifications
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w(`-- 8. NOTIFICATIONS (${notifications.length})`);
w("-- ---------------------------------------------------------------------------");
w();

if (notifications.length === 0) {
  w("-- none in the backup");
  w();
}

for (const notification of notifications) {
  const type = VALID_NOTIFICATION_TYPES.has(notification.type) ? notification.type : "system";

  w("insert into public.notifications (id, title, message, type, read, created_at)");
  w(`values (${sqlStr(notification.id)}, ${sqlStr(notification.title ?? "")}, ` +
    `${sqlStr(notification.message ?? "")}, ${sqlStr(type)}::public.notification_type, ` +
    `${sqlBool(notification.read)}, coalesce(${sqlTimestamp(notification.date)}, now()))`);
  w("on conflict (id) do nothing;");
  w();
}

// ---------------------------------------------------------------------------
// 9. Settings
// ---------------------------------------------------------------------------

w("-- ---------------------------------------------------------------------------");
w("-- 9. SETTINGS");
w("-- ---------------------------------------------------------------------------");
w();

if (settings) {
  w("update public.settings set");
  w(`  business_name = ${sqlStr(settings.businessName ?? "Elite Football Zone")},`);
  w(`  short_name = ${sqlStr(settings.shortName ?? "EFZ")},`);
  w(`  logo = ${sqlStr(settings.logo ?? "")},`);
  w(`  favicon = ${sqlStr(settings.favicon ?? "")},`);
  w(`  whatsapp_number = ${sqlStr(settings.whatsappNumber ?? "")},`);
  w(`  contact_email = ${sqlStr(settings.contactEmail ?? "")},`);
  w(`  default_low_stock_threshold = ${sqlInt(settings.defaultLowStockThreshold, 50)},`);
  w(`  currency_symbol = ${sqlStr(settings.currencySymbol ?? "$")},`);
  w(`  theme = ${sqlStr(settings.theme === "dark" ? "dark" : "light")},`);
  w(`  primary_color = ${sqlStr(settings.primaryColor ?? "#0F172A")},`);
  w(`  secondary_color = ${sqlStr(settings.secondaryColor ?? "#00E676")}`);
  w("where id = true;");
} else {
  w("-- no settings in the backup; 05_seed.sql defaults stand");
}
w();

// ---------------------------------------------------------------------------
// 10. Verification
// ---------------------------------------------------------------------------

const expectedTotals = orders.map(
  (order) => `  (${sqlStr(order.id)}, ${sqlNum(order.total)})`
);

w("-- ---------------------------------------------------------------------------");
w("-- 10. VERIFICATION - compares trigger-computed totals against the backup.");
w("-- Any row this raises is a real arithmetic discrepancy in the old data.");
w("-- ---------------------------------------------------------------------------");
w();
w("do $verify$");
w("declare");
w("  v_row record;");
w("  v_mismatches integer := 0;");
w("begin");
w("  for v_row in");
w("    select e.order_id, e.expected_total, o.total as computed_total");
w("    from (values");
w(expectedTotals.join(",\n"));
w("    ) as e(order_id, expected_total)");
w("    join public.orders o on o.id = e.order_id");
w("    where abs(o.total - e.expected_total) > 0.01");
w("  loop");
w("    v_mismatches := v_mismatches + 1;");
w("    raise warning 'Order % total mismatch: backup %, computed %',");
w("      v_row.order_id, v_row.expected_total, v_row.computed_total;");
w("  end loop;");
w();
w("  if v_mismatches = 0 then");
w(`    raise notice 'All ${orders.length} order totals match the backup.';`);
w("  else");
w("    raise notice '% of ${ORDER_COUNT} order totals differ - review the warnings above.', v_mismatches;");
w("  end if;");
w("end;");
w("$verify$;");
w();
w("commit;");
w();

// ---------------------------------------------------------------------------
// Footer summary
// ---------------------------------------------------------------------------

w("-- ============================================================================");
w("-- IMPORT SUMMARY");
w(`--   profiles         ${users.length}`);
w(`--   user_permissions ${permissionRows.length}`);
w(`--   customers        ${customers.length}`);
w(`--   products         ${products.length}`);
w(`--   orders           ${orders.length}`);
w(`--   order_items      ${itemCount}`);
w(`--   payments         ${paymentCount}`);
w(`--   stock_movements  ${importableMovements.length}`);
w(`--   system_logs      ${logs.length}`);
w(`--   notifications    ${notifications.length}`);
w("-- ============================================================================");

if (warnings.length > 0) {
  w();
  w("-- ---------------------------------------------------------------------------");
  w(`-- ${warnings.length} WARNING(S) RAISED WHILE GENERATING THIS FILE`);
  w("-- ---------------------------------------------------------------------------");
  for (const warning of warnings) w(`--   ${warning}`);
}

let sql = out.join("\n") + "\n";
sql = sql.replace("${ORDER_COUNT}", String(orders.length));

writeFileSync(outputPath, sql, "utf8");

// ---------------------------------------------------------------------------
// Console report
// ---------------------------------------------------------------------------

console.log(`\nWrote ${outputPath.replace(ROOT, ".").replace(/\\/g, "/")}`);
console.log(`  profiles ${users.length} | customers ${customers.length} | products ${products.length}`);
console.log(`  orders ${orders.length} | items ${itemCount} | payments ${paymentCount}`);
console.log(`  movements ${importableMovements.length} | logs ${logs.length} | notifications ${notifications.length}`);

if (warnings.length > 0) {
  console.log(`\n${warnings.length} warning(s):`);
  for (const warning of warnings) console.log(`  - ${warning}`);
}

const accounts = users.filter((user) => user.email);
if (accounts.length > 0) {
  console.log(`\nCreate these ${accounts.length} account(s) in Supabase Auth (Authentication > Users).`);
  console.log("Use the same email; the trigger links each one to its profile automatically:");
  for (const user of accounts) {
    console.log(`  - ${user.email.padEnd(24)} ${user.role} (${user.id})`);
  }
}
