import { AdminUser, Customer, Order, Product, OFFICIAL_PERMISSIONS } from "../types";

export const isValidImageUrl = (imageUrl: string): boolean => {
  try {
    const url = new URL(imageUrl.trim());
    return (url.protocol === "http:" || url.protocol === "https:") && Boolean(url.hostname);
  } catch {
    return false;
  }
};

export const validateProduct = (product: Partial<Product>): { ok: boolean; error?: string; warning?: string } => {
  if (!product.id || !product.name) return { ok: false, error: "Product ID and name are required." };
  if (!product.imageUrl || !isValidImageUrl(product.imageUrl)) {
    return { ok: false, error: "A valid HTTP or HTTPS image URL is required." };
  }
  
  // Financial & Stock Validation
  if (product.stock !== undefined) {
    if (isNaN(product.stock)) return { ok: false, error: "Stock must be a valid number." };
    if (product.stock < 0) return { ok: false, error: "Stock cannot be negative." };
  }
  
  if (product.costPrice !== undefined) {
    if (isNaN(product.costPrice)) return { ok: false, error: "Cost price must be a valid number." };
    if (product.costPrice < 0) return { ok: false, error: "Cost price cannot be negative." };
  }
  
  if (product.sellingPrice !== undefined) {
    if (isNaN(product.sellingPrice)) return { ok: false, error: "Selling price must be a valid number." };
    if (product.sellingPrice < 0) return { ok: false, error: "Selling price cannot be negative." };
  }
  
  if (product.lowStockThreshold !== undefined) {
    if (isNaN(product.lowStockThreshold)) return { ok: false, error: "Low stock threshold must be a valid number." };
    if (product.lowStockThreshold < 0) return { ok: false, error: "Low stock threshold cannot be negative." };
  }

  let warning: string | undefined = undefined;
  if (product.costPrice !== undefined && product.sellingPrice !== undefined && product.sellingPrice < product.costPrice) {
    warning = "Selling price is lower than cost price.";
  }

  return { ok: true, warning };
};

export const validateCustomer = (customer: Partial<Customer>): { ok: boolean; error?: string } => {
  if (!customer.id || !customer.name || !customer.phone) return { ok: false, error: "Customer ID, name, and phone are required." };
  if (!customer.registeredBy) return { ok: false, error: "Customer must be registered by an existing user." };
  return { ok: true };
};

export const validateOrder = (order: Partial<Order>): { ok: boolean; error?: string } => {
  if (!order.id || !order.customerId) return { ok: false, error: "Order ID and Customer ID are required." };
  if (!order.items || order.items.length === 0) return { ok: false, error: "Order must contain at least one item." };

  if (order.total === undefined || isNaN(order.total)) return { ok: false, error: "Order total must be a valid number." };
  if (order.total < 0) return { ok: false, error: "Order total cannot be negative." };

  for (const item of order.items) {
    if (!item.productId || !item.productName) return { ok: false, error: "Each order item requires a product ID and name." };
    if (item.quantity === undefined || isNaN(item.quantity) || item.quantity <= 0) return { ok: false, error: "Order item quantity must be greater than zero." };
    const itemActual = Number(item.actualUnitPrice ?? item.price ?? 0);
    const itemStandard = Number(item.standardUnitPrice ?? item.price ?? 0);
    if (isNaN(itemActual) || itemActual < 0) return { ok: false, error: "Order item negotiated price cannot be negative." };
    if (isNaN(itemStandard) || itemStandard < 0) return { ok: false, error: "Order item standard price cannot be negative." };
  }

  return { ok: true };
};

export const validateUser = (user: Partial<AdminUser>): { ok: boolean; error?: string } => {
  if (!user.id || !user.name || !user.email || !user.role) return { ok: false, error: "User ID, name, email, and role are required." };
  
  if (user.commissionPercentage !== undefined) {
    if (isNaN(user.commissionPercentage)) return { ok: false, error: "Commission percentage must be a valid number." };
    if (user.commissionPercentage < 0 || user.commissionPercentage > 100) {
      return { ok: false, error: "Commission percentage must be between 0 and 100." };
    }
  }

  if (user.permissions) {
    for (const p of user.permissions) {
      if (!OFFICIAL_PERMISSIONS.includes(p as any)) {
        return { ok: false, error: `Invalid permission detected: ${p}.` };
      }
    }
    // Check for duplicates
    if (new Set(user.permissions).size !== user.permissions.length) {
      return { ok: false, error: "Duplicate permissions detected." };
    }
  }

  return { ok: true };
};
