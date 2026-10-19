/**
 * Where an order came from, read only from what the database already records: the customer app's checkout (_customer_create_order) always starts the
 * order's delivery notes with this sentence. Read-only; nothing is written or guessed. Orders staff create, and website requests staff convert, show no badge.
 */
export const CUSTOMER_APP_NOTE_PREFIX = "Placed in the customer app.";

export type OrderChannelFilter = "all" | "customer_app";

export const isCustomerAppOrder = (order: { deliveryNotes?: string | null }): boolean =>
  (order.deliveryNotes ?? "").trimStart().startsWith(CUSTOMER_APP_NOTE_PREFIX);

export const matchesChannel = (order: { deliveryNotes?: string | null }, filter: OrderChannelFilter): boolean =>
  filter === "all" || isCustomerAppOrder(order);
