import { storageCore } from "../storage/core";
import { PRODUCTS_KEY, INITIALIZED_KEY } from "../storage/keys";
import { Product } from "../types";
import { MOCK_PRODUCTS } from "../data";

// Defense-in-depth: sanitize a single product's numeric fields
const sanitizeProduct = (p: any): Product => {
  return {
    ...p,
    imageUrl: p.imageUrl,
    stock: Math.max(0, Number(p.stock) || 0),
    costPrice: Math.max(0, Number(p.costPrice) || 0),
    sellingPrice: Math.max(0, Number(p.sellingPrice) || Number(p.price) || 0),
    price: Math.max(0, Number(p.price) || Number(p.sellingPrice) || 0),
    lowStockThreshold: Math.max(0, Number(p.lowStockThreshold) || 0),
  };
};

export const productService = {
  getProducts: (): Product[] => {
    const stored = storageCore.get(PRODUCTS_KEY);
    if (stored) {
      const products: Product[] = JSON.parse(stored);
      const repaired = products.map(sanitizeProduct);

      if (JSON.stringify(repaired) !== JSON.stringify(products)) {
        productService.saveProducts(repaired);
      }
      return repaired;
    }
    
    if (typeof window !== "undefined" && localStorage.getItem(INITIALIZED_KEY) !== "true") {
      productService.saveProducts(MOCK_PRODUCTS);
      return MOCK_PRODUCTS;
    }
    
    return [];
  },

  saveProducts: (products: Product[]) => {
    // Sanitize before persisting to prevent corrupted data from being saved
    const sanitized = products.map(sanitizeProduct);
    storageCore.set(PRODUCTS_KEY, JSON.stringify(sanitized));
  }
};
