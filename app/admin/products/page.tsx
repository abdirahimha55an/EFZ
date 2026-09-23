"use client";

import { useCallback, useEffect, useState } from "react";
import { Plus, Search, Edit, Trash2, X, AlertTriangle, CheckCircle, Package, Link as LinkIcon, RefreshCcw, Loader2 } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { AdminProfile, Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { isValidImageUrl, validateProduct } from "@/lib/validators";

export default function ProductsPage() {
  const [products, setProducts] = useState<Product[]>([]);
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingProduct, setEditingProduct] = useState<Product | null>(null);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);
  const [imagePreviewError, setImagePreviewError] = useState(false);

  // Form state
  const [formData, setFormData] = useState<Omit<Product, 'id' | 'isWholesale'>>({
    name: "",
    category: "Football",
    price: 0,
    costPrice: 0,
    sellingPrice: 0,
    stock: 0,
    lowStockThreshold: 50,
    size: "Size 5",
    imageUrl: "",
    description: "",
    durability: "High",
    surfaceType: "All Surfaces"
  });

  // Re-reads the catalog from Supabase. Every mutation ends with this rather
  // than patching local state, so the numbers on screen are always the numbers
  // the database actually holds after its triggers have run.
  const refresh = useCallback(async () => {
    const db = getDb();
    const [nextProducts, nextProfile] = await Promise.all([
      db.products.list(),
      db.auth.getProfile(),
    ]);
    setProducts(nextProducts);
    setProfile(nextProfile);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        setIsLoading(true);
        const db = getDb();
        const [nextProducts, nextProfile] = await Promise.all([
          db.products.list(),
          db.auth.getProfile(),
        ]);
        if (cancelled) return;
        setProducts(nextProducts);
        setProfile(nextProfile);
        setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  // Notifications timeout
  useEffect(() => {
    if (notification) {
      const timer = setTimeout(() => setNotification(null), 3000);
      return () => clearTimeout(timer);
    }
  }, [notification]);

  const perms = derivePermissions(profile);
  const canViewInventory = perms.viewInventory;
  const canAddProducts = perms.addProducts;
  const canEditProducts = perms.editProducts;
  const canDeleteProducts = perms.deleteProducts;
  const canAdjustStock = perms.adjustStock;

  const showNotification = (type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
  };

  const handleRefresh = async () => {
    try {
      setIsSaving(true);
      await refresh();
      showNotification('success', 'Catalog refreshed');
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const openAddModal = () => {
    setEditingProduct(null);
    setImagePreviewError(false);
    setFormData({
      name: "",
      category: "Football",
      price: 0,
      costPrice: 0,
      sellingPrice: 0,
      stock: 0,
      lowStockThreshold: 50,
      size: "Size 5",
      imageUrl: "",
      description: "",
      durability: "High",
      surfaceType: "All Surfaces"
    });
    setIsModalOpen(true);
  };

  const openEditModal = (product: Product) => {
    if (!canEditProducts) {
      showNotification('error', 'Permission denied: You are not allowed to edit products.');
      return;
    }
    setEditingProduct(product);
    setImagePreviewError(false);
    setFormData({
      name: product.name,
      category: product.category,
      price: product.sellingPrice || product.price || 0,
      costPrice: product.costPrice || 0,
      sellingPrice: product.sellingPrice || product.price || 0,
      stock: product.stock,
      lowStockThreshold: product.lowStockThreshold || 50,
      size: product.size,
      imageUrl: product.imageUrl,
      description: product.description,
      durability: product.durability,
      surfaceType: product.surfaceType
    });
    setIsModalOpen(true);
  };

  // Retires the product instead of erasing the row. Past orders keep pointing
  // at it, so the order history and its profit figures stay intact.
  const handleDelete = async (id: string) => {
    if (!canDeleteProducts) {
      showNotification('error', 'Permission denied: You are not allowed to delete products.');
      return;
    }

    const product = products.find(p => p.id === id);
    const confirmed = confirm(
      `Remove "${product?.name || id}" from the catalog?\n\n` +
      `It will disappear from the product list and the public site, but stays on every past order.`
    );
    if (!confirmed) return;

    try {
      setIsSaving(true);
      const db = getDb();
      await db.products.deactivate(id);
      await db.logs.write({
        category: 'INVENTORY',
        severity: 'WARNING',
        message: `Product removed from catalog: ${product?.name || id}`,
        targetId: id,
      });
      await refresh();
      showNotification('success', 'Product removed from the catalog');
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (editingProduct) {
      if (!canEditProducts) {
        showNotification('error', 'Permission denied: You are not allowed to edit products.');
        return;
      }
    } else {
      if (!canAddProducts) {
        showNotification('error', 'Permission denied: You are not allowed to add new products.');
        return;
      }
    }
    
    // Parse form values to numbers to prevent any string/NaN issues
    const validationData = {
      ...formData,
      id: editingProduct?.id || "temp-id",
      stock: Number(formData.stock),
      costPrice: Number(formData.costPrice),
      sellingPrice: Number(formData.sellingPrice),
      lowStockThreshold: Number(formData.lowStockThreshold)
    };

    const validation = validateProduct(validationData);
    if (!validation.ok) {
      showNotification('error', validation.error || 'Invalid product data');
      return;
    }

    const savedData = {
      ...formData,
      stock: Number(formData.stock),
      costPrice: Number(formData.costPrice),
      sellingPrice: Number(formData.sellingPrice),
      price: Number(formData.sellingPrice), // Keep legacy price in sync
      lowStockThreshold: Number(formData.lowStockThreshold)
    };

    try {
      setIsSaving(true);
      const db = getDb();

      if (editingProduct) {
        const oldStock = editingProduct.stock;
        const newStock = savedData.stock;
        const stockDiff = newStock - oldStock;

        // products.update deliberately ignores stock. Stock only ever moves
        // through adjust_stock(), which writes the ledger entry in the same
        // transaction, so the movement history can never go out of step.
        await db.products.update(editingProduct.id, savedData);

        if (stockDiff !== 0) {
          await db.inventory.adjust(
            editingProduct.id,
            stockDiff,
            `Product stock manually updated from ${oldStock} to ${newStock}`
          );
        }

        await db.logs.write({
          category: 'INVENTORY',
          severity: 'INFO',
          message: `Product updated: ${savedData.name}`,
          targetId: editingProduct.id,
          metadata: {
            oldValue: oldStock,
            newValue: newStock,
            field: 'stock',
            source: 'Product Catalog',
          },
        });

        showNotification(
          'success',
          validation.warning ? `Product updated. Warning: ${validation.warning}` : 'Product updated successfully'
        );
      } else {
        // Created with zero stock, then stocked through the ledger, so a new
        // product's opening quantity is a movement like any other.
        const created = await db.products.create({
          ...savedData,
          stock: 0,
          isWholesale: true,
        });

        if (savedData.stock > 0) {
          await db.inventory.adjust(
            created.id,
            savedData.stock,
            'Initial stock for new product',
            'import'
          );
        }

        await db.logs.write({
          category: 'INVENTORY',
          severity: 'INFO',
          message: `New product created: ${savedData.name}`,
          targetId: created.id,
          metadata: {
            oldValue: 0,
            newValue: savedData.stock,
            field: 'stock',
            source: 'Product Catalog',
          },
        });

        showNotification(
          'success',
          validation.warning ? `New product added. Warning: ${validation.warning}` : 'New product added successfully'
        );
      }

      await refresh();
      setIsModalOpen(false);
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const handleQuickStockUpdate = async (id: string, amount: number) => {
    if (!canAdjustStock) {
      showNotification('error', 'Permission denied: You are not allowed to adjust stock.');
      return;
    }
    const product = products.find(p => p.id === id);
    if (!product) return;

    // The database refuses this too; checking here just avoids a round trip.
    if (product.stock + amount < 0) {
      showNotification('error', 'Stock cannot be reduced below 0.');
      return;
    }

    const oldStock = product.stock;
    const newStock = oldStock + amount;
    const action = amount > 0 ? 'increased' : 'decreased';

    try {
      setIsSaving(true);
      const db = getDb();

      await db.inventory.adjust(
        id,
        amount,
        `Quick stock adjustment: ${amount > 0 ? '+' : ''}${amount}`
      );

      await db.logs.write({
        category: 'INVENTORY',
        severity: 'INFO',
        message: `Stock ${action} for ${product.name}: ${oldStock} -> ${newStock}`,
        targetId: id,
        metadata: {
          oldValue: oldStock,
          newValue: newStock,
          field: 'stock',
          source: 'Quick Adjust',
        },
      });

      await refresh();
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const filteredProducts = products.filter(product => 
    product.name.toLowerCase().includes(searchTerm.toLowerCase()) ||
    product.category.toLowerCase().includes(searchTerm.toLowerCase())
  );

  const getInventoryStatus = (product: Product) => {
    if (product.stock === 0) return { label: 'Out of Stock', color: 'text-red-600 bg-red-100', icon: <AlertTriangle className="h-3 w-3" /> };
    if (product.stock <= product.lowStockThreshold) return { label: 'Low Stock', color: 'text-amber-600 bg-amber-100', icon: <AlertTriangle className="h-3 w-3" /> };
    return { label: 'In Stock', color: 'text-green-600 bg-green-100', icon: <CheckCircle className="h-3 w-3" /> };
  };

  if (isLoading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading catalog…</p>
      </div>
    );
  }

  if (loadError) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-4 py-16 text-center">
          <AlertTriangle className="h-8 w-8 text-red-500" />
          <div>
            <h2 className="font-heading text-lg font-bold text-slate-900">Could not load the catalog</h2>
            <p className="mt-1 max-w-md text-xs text-slate-500">{loadError}</p>
          </div>
          <Button onClick={handleRefresh} variant="outline" size="sm" className="rounded-lg text-xs">
            <RefreshCcw className="mr-1.5 h-3.5 w-3.5" /> Try again
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-8 relative">
      {/* Toast Notification */}
      {notification && (
        <div className={`fixed top-4 right-4 z-[100] flex items-center gap-3 px-4 py-3 rounded-lg shadow-lg border animate-in fade-in slide-in-from-top-4 duration-300 ${
          notification.type === 'success' ? 'bg-green-50 border-green-200 text-green-800' : 'bg-red-50 border-red-200 text-red-800'
        }`}>
          {notification.type === 'success' ? <CheckCircle className="h-5 w-5" /> : <AlertTriangle className="h-5 w-5" />}
          <p className="font-medium">{notification.message}</p>
        </div>
      )}

      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Products & Inventory</h1>
          <p className="text-slate-400 mt-0.5 flex items-center gap-2 text-xs font-medium">
            <Package className="h-3.5 w-3.5 text-brand-blue" /> 
            Manage your catalog and monitor real-time stock levels.
          </p>
        </div>
        <div className="flex gap-2">
          <Button onClick={handleRefresh} disabled={isSaving} variant="outline" size="sm" className="text-slate-500 border-slate-200 rounded-lg h-10 px-4 text-xs">
            <RefreshCcw className={cn("h-3.5 w-3.5 mr-1.5", isSaving && "animate-spin")} /> Refresh
          </Button>
          {canAddProducts && (
            <Button onClick={openAddModal} disabled={isSaving} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
              <Plus className="h-4 w-4 mr-1" /> Add New Product
            </Button>
          )}
        </div>
      </div>

      <Card className="border-none shadow-sm overflow-hidden">
        <CardContent className="p-0">
          <div className="p-4 border-b border-slate-200 bg-slate-50/50 flex flex-col md:flex-row gap-3 justify-between items-center">
            <div className="relative w-full md:w-80">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400" />
              <Input 
                placeholder="Search products, categories..." 
                className="pl-9 h-9 bg-white border-slate-200 text-xs rounded-lg"
                value={searchTerm}
                onChange={(e) => setSearchTerm(e.target.value)}
              />
            </div>
            <div className="flex gap-3 text-[9px] font-bold text-slate-400 uppercase tracking-widest">
              <span className="flex items-center gap-1.5"><div className="w-1.5 h-1.5 rounded-full bg-green-500" /> In Stock</span>
              <span className="flex items-center gap-1.5"><div className="w-1.5 h-1.5 rounded-full bg-amber-500" /> Low Stock</span>
              <span className="flex items-center gap-1.5"><div className="w-1.5 h-1.5 rounded-full bg-red-500" /> Out of Stock</span>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="text-[9px] text-slate-400 uppercase bg-slate-50/80 border-b border-slate-100 font-bold tracking-widest">
                <tr>
                  <th className="px-6 py-3 w-[260px]">Product Info</th>
                  <th className="px-6 py-3 w-[100px]">Category</th>
                  <th className="px-6 py-3 w-[200px]">Financials (Unit / Total)</th>
                  <th className="px-6 py-3 w-[120px]">Status</th>
                  <th className="px-6 py-3 w-[140px]">Inventory Level</th>
                  <th className="px-6 py-3 w-[80px] text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                  {filteredProducts.map((product) => {
                    const status = getInventoryStatus(product);
                    return (
                      <tr key={product.id} className="bg-white border-b border-slate-50 hover:bg-slate-50/50 transition-colors group">
                        <td className="px-6 py-3">
                          <div className="flex items-center gap-3">
                            <div className="relative h-10 w-10 rounded-lg overflow-hidden bg-slate-100 flex-shrink-0 border border-slate-100 shadow-sm">
                              <img 
                                src={isValidImageUrl(product.imageUrl) ? product.imageUrl : 'https://images.unsplash.com/photo-1543152507-64010996fb28?auto=format&fit=crop&q=80&w=800'} 
                                alt={product.name} 
                                className="h-full w-full object-cover"
                                onError={(e) => { e.currentTarget.src = 'https://images.unsplash.com/photo-1543152507-64010996fb28?auto=format&fit=crop&q=80&w=800'; }}
                              />
                            </div>
                            <div className="min-w-0">
                              <p className="font-bold text-slate-900 group-hover:text-brand-blue transition-colors truncate">{product.name}</p>
                              <p className="text-slate-400 text-[10px] mt-0.5 truncate">{product.description || "No description available"}</p>
                            </div>
                          </div>
                        </td>
                        <td className="px-6 py-3">
                          <span className="inline-block px-1.5 py-0.5 bg-slate-100 text-slate-500 rounded text-[8px] font-bold uppercase tracking-wider">{product.category}</span>
                          <p className="text-slate-400 text-[9px] mt-0.5 font-medium">{product.size}</p>
                        </td>
                        <td className="px-6 py-3">
                          <div className="space-y-1">
                            <div className="flex items-center gap-1.5">
                              <span className="text-[10px] text-slate-400 font-bold uppercase w-8">Cost</span>
                              <span className="text-xs font-bold text-slate-600">${canViewInventory ? (product.costPrice || 0).toFixed(0) : '--'}</span>
                              <span className="text-[9px] text-slate-300 mx-1">→</span>
                              <span className="text-xs font-bold text-slate-900">${(product.sellingPrice || product.price || 0).toFixed(0)}</span>
                              <span className="text-[10px] text-slate-400 font-bold uppercase">Sell</span>
                            </div>
                            <div className="flex items-center gap-3">
                              <div className="flex items-center gap-1 font-bold text-[10px]">
                                <Plus className="h-2 w-2" />
                                <span className={canViewInventory ? 'text-green-600' : 'text-slate-400'}>
                                  {canViewInventory ? `Profit: ${((product.sellingPrice || product.price || 0) - (product.costPrice || 0)).toFixed(0)}/u` : 'Profit hidden'}
                                </span>
                              </div>
                              <div className="flex items-center gap-1 font-bold text-[10px]">
                                <span className={canViewInventory ? 'text-brand-blue' : 'text-slate-400'}>
                                  {canViewInventory ? `Total: ${(((product.sellingPrice || product.price || 0) - (product.costPrice || 0)) * product.stock).toFixed(0)}` : 'Total hidden'}
                                </span>
                              </div>
                            </div>
                          </div>
                        </td>
                        <td className="px-6 py-3">
                          <span className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-[9px] font-bold uppercase ${status.color.replace('bg-', 'bg-opacity-50 bg-')}`}>
                            {status.label}
                          </span>
                        </td>
                        <td className="px-6 py-3">
                          <div className="flex items-center gap-2">
                            <div className="flex items-center bg-white border border-slate-200 rounded overflow-hidden shadow-sm h-7">
                              <button
                                onClick={() => canAdjustStock ? handleQuickStockUpdate(product.id, -1) : undefined}
                                className={cn(
                                  "px-2 text-slate-400 transition-colors border-r border-slate-200 font-bold",
                                  canAdjustStock && !isSaving ? "hover:bg-slate-50 hover:text-slate-900" : "cursor-not-allowed opacity-50"
                                )}
                                disabled={!canAdjustStock || isSaving}
                              >-</button>
                              <div className="w-8 text-center font-bold text-[10px] text-slate-900">
                                {canViewInventory ? product.stock : '—'}
                              </div>
                              <button
                                onClick={() => canAdjustStock ? handleQuickStockUpdate(product.id, 1) : undefined}
                                className={cn(
                                  "px-2 text-slate-400 transition-colors border-l border-slate-200 font-bold",
                                  canAdjustStock && !isSaving ? "hover:bg-slate-50 hover:text-slate-900" : "cursor-not-allowed opacity-50"
                                )}
                                disabled={!canAdjustStock || isSaving}
                              >+</button>
                            </div>
                            <div className="flex flex-col leading-none">
                              <span className="text-[8px] text-slate-400 font-bold uppercase">Min</span>
                              <span className="text-[10px] text-slate-700 font-bold">{product.lowStockThreshold}</span>
                            </div>
                          </div>
                        </td>
                        <td className="px-6 py-3 text-right">
                          <div className="flex justify-end gap-1.5 opacity-0 group-hover:opacity-100 transition-opacity">
                            {canEditProducts && (
                              <Button onClick={() => openEditModal(product)} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-brand-blue hover:bg-blue-50 rounded-md">
                                <Edit className="h-3.5 w-3.5" />
                              </Button>
                            )}
                            {canDeleteProducts && (
                              <Button onClick={() => handleDelete(product.id)} disabled={isSaving} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-md">
                                <Trash2 className="h-3.5 w-3.5" />
                              </Button>
                            )}
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                {filteredProducts.length === 0 && (
                  <tr>
                    <td colSpan={6} className="px-6 py-16 text-center text-slate-500">
                      <div className="flex flex-col items-center gap-3">
                        <div className="h-12 w-12 rounded-full bg-slate-50 flex items-center justify-center text-slate-300">
                          <Search className="h-6 w-6" />
                        </div>
                        <p className="font-bold text-slate-400 uppercase tracking-widest text-[10px]">No results found matching your search</p>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {/* Add/Edit Product Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 bg-slate-900/60 backdrop-blur-sm z-[1000] flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl shadow-2xl w-full max-w-2xl max-h-[95vh] overflow-y-auto animate-in zoom-in duration-200">
            <div className="sticky top-0 bg-white flex items-center justify-between p-6 border-b z-10">
              <h2 className="font-heading text-2xl font-bold text-slate-900">{editingProduct ? 'Edit Product' : 'Add New Product'}</h2>
              <button onClick={() => setIsModalOpen(false)} className="text-slate-400 hover:text-slate-600 transition-colors p-1 hover:bg-slate-100 rounded-full">
                <X className="h-6 w-6" />
              </button>
            </div>
            
            <form onSubmit={handleSubmit} className="p-6 space-y-6">
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                {/* Left Side: General Info */}
                <div className="space-y-4">
                  <div>
                    <label className="block text-sm font-bold text-slate-700 mb-1">Product Name *</label>
                    <Input 
                      required 
                      value={formData.name} 
                      onChange={e => setFormData({...formData, name: e.target.value})}
                      placeholder="e.g., EFZ Pro Match Football"
                    />
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <label className="block text-sm font-bold text-slate-700 mb-1">Category</label>
                      <select 
                        className="flex h-10 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:ring-2 focus:ring-brand-green outline-none transition-all"
                        value={formData.category}
                        onChange={e => setFormData({...formData, category: e.target.value as Product["category"]})}
                      >
                        <option value="Football">Football</option>
                        <option value="Futsal">Futsal</option>
                        <option value="Accessories">Accessories</option>
                      </select>
                    </div>
                    <div>
                      <label className="block text-sm font-bold text-slate-700 mb-1">Size / Specification</label>
                      <Input 
                        required 
                        value={formData.size} 
                        onChange={e => setFormData({...formData, size: e.target.value})}
                        placeholder="e.g., Size 5"
                      />
                    </div>
                  </div>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <label className="block text-xs font-bold text-slate-500 uppercase mb-1">Cost Price ($)</label>
                      <Input 
                        required 
                        type="number" 
                        step="0.01" 
                        value={formData.costPrice} 
                        onChange={e => setFormData({...formData, costPrice: parseFloat(e.target.value) || 0})}
                        className="h-10 bg-slate-50 border-slate-200"
                      />
                    </div>
                    <div>
                      <label className="block text-xs font-bold text-slate-500 uppercase mb-1">Selling Price ($)</label>
                      <Input 
                        required 
                        type="number" 
                        step="0.01" 
                        value={formData.sellingPrice} 
                        onChange={e => setFormData({...formData, sellingPrice: parseFloat(e.target.value) || 0, price: parseFloat(e.target.value) || 0})}
                        className="h-10 border-brand-blue/30 focus:border-brand-blue"
                      />
                    </div>
                  </div>

                  {/* Automatic Profit Preview */}
                  <div className="bg-slate-900 rounded-xl p-4 text-white shadow-xl">
                    <div className="flex justify-between items-center mb-3 border-b border-white/10 pb-2">
                      <span className="text-[10px] font-bold uppercase tracking-widest text-slate-400">Profit Projection</span>
                      {formData.sellingPrice < formData.costPrice && formData.costPrice > 0 && (
                        <span className="text-[10px] bg-red-500 text-white px-2 py-0.5 rounded font-bold animate-pulse">Loss Warning</span>
                      )}
                    </div>
                    <div className="grid grid-cols-2 gap-4">
                      <div>
                        <p className="text-[9px] text-slate-400 uppercase font-bold">Margin per Unit</p>
                        <p className={cn("text-lg font-bold", (formData.sellingPrice - formData.costPrice) >= 0 ? "text-brand-green" : "text-red-400")}>
                          ${(formData.sellingPrice - formData.costPrice).toFixed(2)}
                        </p>
                      </div>
                      <div className="text-right">
                        <p className="text-[9px] text-slate-400 uppercase font-bold">Expected Total Profit</p>
                        <p className={cn("text-lg font-bold", (formData.sellingPrice - formData.costPrice) * formData.stock >= 0 ? "text-brand-blue" : "text-red-400")}>
                          ${((formData.sellingPrice - formData.costPrice) * formData.stock).toFixed(2)}
                        </p>
                      </div>
                    </div>
                    <div className="mt-3 grid grid-cols-2 gap-2 border-t border-white/5 pt-3">
                      <div>
                        <p className="text-[8px] text-slate-500 uppercase font-bold">Total Cost Value</p>
                        <p className="text-xs font-bold text-slate-300">${(formData.costPrice * formData.stock).toFixed(2)}</p>
                      </div>
                      <div className="text-right">
                        <p className="text-[8px] text-slate-500 uppercase font-bold">Total Selling Value</p>
                        <p className="text-xs font-bold text-slate-300">${(formData.sellingPrice * formData.stock).toFixed(2)}</p>
                      </div>
                    </div>
                  </div>
                  <div>
                    <label className="block text-sm font-bold text-slate-700 mb-1">Description</label>
                    <textarea 
                      className="flex min-h-[100px] w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm focus:ring-2 focus:ring-brand-green outline-none"
                      value={formData.description}
                      onChange={e => setFormData({...formData, description: e.target.value})}
                      placeholder="Product details, materials, use cases..."
                    />
                  </div>
                </div>

                {/* Right Side: Image & Inventory */}
                <div className="space-y-4">
                  <div className="space-y-4">
                    <label className="block text-sm font-bold text-slate-700">Product Image</label>
                    
                    <div className="relative aspect-video rounded-xl bg-slate-50 border border-slate-200 overflow-hidden flex items-center justify-center">
                      {isValidImageUrl(formData.imageUrl) && !imagePreviewError ? (
                        <img
                          src={formData.imageUrl}
                          alt="Product preview"
                          className="h-full w-full object-cover"
                          onError={() => setImagePreviewError(true)}
                        />
                      ) : (
                        <div className="p-6 text-center text-slate-400">
                          <p className="text-xs font-bold">Image preview unavailable</p>
                          <p className="text-[10px] mt-1">Enter a valid image URL to preview it.</p>
                        </div>
                      )}
                    </div>

                    <div className="relative">
                      <label className="block text-sm font-bold text-slate-700 mb-1">Image URL</label>
                      <div className="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
                        <LinkIcon className="h-4 w-4 text-slate-400" />
                      </div>
                      <Input 
                        value={formData.imageUrl}
                        onChange={e => {
                          setImagePreviewError(false);
                          setFormData({...formData, imageUrl: e.target.value});
                        }}
                        placeholder="Paste image URL..."
                        className="pl-10 text-xs"
                      />
                    </div>
                    <p className="text-[10px] text-slate-400">Use a direct URL to an image hosted online.</p>
                  </div>

                  <div className="grid grid-cols-2 gap-4">
                    <div className="p-3 bg-slate-50 rounded-lg border border-slate-100">
                      <label className="block text-xs font-bold text-slate-500 uppercase mb-1">Current Stock</label>
                      <Input 
                        required 
                        type="number" 
                        value={formData.stock} 
                        onChange={e => setFormData({...formData, stock: parseInt(e.target.value) || 0})}
                        className="bg-white"
                      />
                    </div>
                    <div className="p-3 bg-slate-50 rounded-lg border border-slate-100">
                      <label className="block text-xs font-bold text-slate-500 uppercase mb-1">Low-Stock Alert at</label>
                      <Input 
                        required 
                        type="number" 
                        value={formData.lowStockThreshold} 
                        onChange={e => setFormData({...formData, lowStockThreshold: parseInt(e.target.value) || 0})}
                        className="bg-white"
                      />
                    </div>
                  </div>
                </div>
              </div>

              <div className="flex gap-3 pt-4 border-t">
                <Button
                  type="button"
                  variant="ghost"
                  disabled={isSaving}
                  className="flex-1 text-slate-500 font-bold"
                  onClick={() => setIsModalOpen(false)}
                >
                  Cancel
                </Button>
                <Button
                  type="submit"
                  disabled={isSaving}
                  className="flex-1 bg-brand-blue hover:bg-brand-blue/90 text-white font-bold py-6 shadow-lg shadow-blue-200"
                >
                  {isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                  {editingProduct ? 'Save Changes' : 'Create Product'}
                </Button>
              </div>
            </form>
          </div>
        </div>
      )}
    </div>
  );
}
