import { backupService } from '../lib/services/backup.service';
import { storage } from '../lib/storage';
import { customerService } from '../lib/services/customer.service';

const store = new Map<string, string>();

globalThis.window = {
  crypto: {
    randomUUID: () => `uuid-${Math.random().toString(16).slice(2)}`,
  },
} as any;

globalThis.localStorage = {
  getItem: (key: string) => (store.has(key) ? store.get(key)! : null),
  setItem: (key: string, value: string) => {
    store.set(String(key), String(value));
  },
  removeItem: (key: string) => {
    store.delete(String(key));
  },
  clear: () => {
    store.clear();
  },
} as any;

const approx = (actual: number, expected: number) => Math.abs(actual - expected) < 1e-9;

const run = () => {
  const firstRun = backupService.activateApprovedHistoricalMigration();
  const orders = storage.getOrders();
  const customers = customerService.getCustomers();

  const totalUnits = orders.reduce((sum, order) => sum + order.items.reduce((itemSum, item) => itemSum + Number(item.quantity || 0), 0), 0);
  const totalRevenue = orders.reduce((sum, order) => sum + Number(order.total || 0), 0);
  const totalCost = orders.reduce((sum, order) => sum + Number(order.cost || 0), 0);
  const totalProfit = orders.reduce((sum, order) => sum + Number(order.grossProfit || 0), 0);

  const revenueByProduct = orders.flatMap((order) => order.items).reduce<Record<string, { units: number; revenue: number }>>((acc, item) => {
    const key = item.productName || item.designName || item.productId;
    const qty = Number(item.quantity || 0);
    const revenue = Number(item.actualUnitPrice ?? item.price ?? item.standardUnitPrice ?? 0) * qty;
    const current = acc[key] ?? { units: 0, revenue: 0 };
    current.units += qty;
    current.revenue += revenue;
    acc[key] = current;
    return acc;
  }, {});

  const customerSummary = [
    'Sky Dome',
    'Dhimbil',
    'Goobe Stadium',
    'Hayaan',
    'Abdinasir Shukri',
  ].map((name) => {
    const matches = orders.filter((order) => order.customer === name);
    return {
      name,
      parentOrders: matches.length,
      units: matches.reduce((sum, order) => sum + order.items.reduce((itemSum, item) => itemSum + Number(item.quantity || 0), 0), 0),
      revenue: matches.reduce((sum, order) => sum + Number(order.total || 0), 0),
    };
  });

  const checks = [
    ['activated', firstRun, true],
    ['exact parent orders', orders.length, 7],
    ['exact units', totalUnits, 11],
    ['exact revenue', totalRevenue, 119],
    ['exact cost', totalCost, 73.7],
    ['exact gross profit', totalProfit, 45.3],
    ['Nexus units', revenueByProduct['EFZ - Nexus']?.units ?? 0, 6],
    ['Nexus revenue', revenueByProduct['EFZ - Nexus']?.revenue ?? 0, 65.5],
    ['Fire Ball units', revenueByProduct['EFZ - Fire Ball']?.units ?? 0, 5],
    ['Fire Ball revenue', revenueByProduct['EFZ - Fire Ball']?.revenue ?? 0, 53.5],
    ['Sky Dome parent orders', customerSummary.find((row) => row.name === 'Sky Dome')?.parentOrders ?? 0, 2],
    ['Sky Dome units', customerSummary.find((row) => row.name === 'Sky Dome')?.units ?? 0, 4],
    ['Sky Dome revenue', customerSummary.find((row) => row.name === 'Sky Dome')?.revenue ?? 0, 40],
    ['Dhimbil parent orders', customerSummary.find((row) => row.name === 'Dhimbil')?.parentOrders ?? 0, 2],
    ['Dhimbil units', customerSummary.find((row) => row.name === 'Dhimbil')?.units ?? 0, 3],
    ['Dhimbil revenue', customerSummary.find((row) => row.name === 'Dhimbil')?.revenue ?? 0, 32],
    ['Goobe Stadium parent orders', customerSummary.find((row) => row.name === 'Goobe Stadium')?.parentOrders ?? 0, 1],
    ['Goobe Stadium units', customerSummary.find((row) => row.name === 'Goobe Stadium')?.units ?? 0, 2],
    ['Goobe Stadium revenue', customerSummary.find((row) => row.name === 'Goobe Stadium')?.revenue ?? 0, 23],
    ['Hayaan parent orders', customerSummary.find((row) => row.name === 'Hayaan')?.parentOrders ?? 0, 1],
    ['Hayaan units', customerSummary.find((row) => row.name === 'Hayaan')?.units ?? 0, 1],
    ['Hayaan revenue', customerSummary.find((row) => row.name === 'Hayaan')?.revenue ?? 0, 11],
    ['Abdinasir Shukri parent orders', customerSummary.find((row) => row.name === 'Abdinasir Shukri')?.parentOrders ?? 0, 1],
    ['Abdinasir Shukri units', customerSummary.find((row) => row.name === 'Abdinasir Shukri')?.units ?? 0, 1],
    ['Abdinasir Shukri revenue', customerSummary.find((row) => row.name === 'Abdinasir Shukri')?.revenue ?? 0, 13],
    ['no duplicate IDs', new Set(orders.map((order) => order.id)).size, orders.length],
  ] as const;

  const failed = checks.filter(([label, actual, expected]) => {
    if (typeof actual === 'number' && typeof expected === 'number') {
      return !approx(actual, expected);
    }
    return actual !== expected;
  });

  if (failed.length > 0) {
    console.error('FAILED CHECKS');
    console.error(JSON.stringify(failed, null, 2));
    process.exit(1);
  }

  const secondRun = backupService.activateApprovedHistoricalMigration();
  const secondOrders = storage.getOrders();
  if (secondRun !== false || secondOrders.length !== orders.length) {
    console.error('FAILED IDEMPOTENCE CHECK');
    console.error(JSON.stringify({ secondRun, secondOrdersLength: secondOrders.length, expected: orders.length }, null, 2));
    process.exit(1);
  }

  console.log(JSON.stringify({
    migrated: true,
    orderCount: orders.length,
    units: totalUnits,
    revenue: totalRevenue,
    cost: totalCost,
    grossProfit: totalProfit,
    revenueByProduct,
    customerSummary,
    duplicateParentOrders: false,
    idempotent: true,
  }, null, 2));
};

run();
