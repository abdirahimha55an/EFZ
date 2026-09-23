"use client";

import { useCallback, useEffect, useState } from "react";
import { 
  Users, 
  UserPlus, 
  Shield, 
  Mail, 
  Phone, 
  Edit, 
  Trash2, 
  CheckCircle, 
  XCircle, 
  Search, 
  Filter,
  ChevronRight,
  ShieldAlert,
  ShieldCheck,
  DollarSign,
  TrendingUp,
  UserCheck,
  X,
  User,
  Plus,
  Loader2,
  RefreshCcw,
  Info
} from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { AdminUser, UserRole, Permission } from "@/lib/types";
import type { OfficerCommissionSummaryRow } from "@/lib/supabase/database.types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { validateUser } from "@/lib/validators";

const ROLES: UserRole[] = ['Super Admin', 'Manager', 'Marketing Officer', 'Inventory Staff', 'Delivery Staff'];

const PERMISSIONS_LIST: { id: Permission, label: string, category: string }[] = [
  { id: 'view_dashboard', label: 'View Dashboard', category: 'General' },
  { id: 'change_settings', label: 'Change System Settings', category: 'General' },
  { id: 'manage_users', label: 'Manage Admin Users', category: 'General' },
  
  { id: 'view_products', label: 'View Catalog', category: 'Inventory' },
  { id: 'add_products', label: 'Add New Products', category: 'Inventory' },
  { id: 'edit_products', label: 'Modify Products', category: 'Inventory' },
  { id: 'delete_products', label: 'Remove Products', category: 'Inventory' },
  { id: 'view_inventory', label: 'Monitor Stock Levels', category: 'Inventory' },
  { id: 'adjust_stock', label: 'Manual Stock Adjust', category: 'Inventory' },
  
  { id: 'view_orders', label: 'View All Orders', category: 'Orders' },
  { id: 'create_orders', label: 'Place New Orders', category: 'Orders' },
  { id: 'edit_orders', label: 'Update Order Status', category: 'Orders' },
  { id: 'delete_orders', label: 'Delete Orders', category: 'Orders' },
  { id: 'override_order_status', label: 'Override Locked Order Statuses', category: 'Orders' },
  
  { id: 'view_customers', label: 'View Customer List', category: 'CRM' },
  { id: 'add_customers', label: 'Register New Customers', category: 'CRM' },
  { id: 'edit_customers', label: 'Edit Customer Info', category: 'CRM' },
  { id: 'delete_customers', label: 'Delete Customers', category: 'CRM' },
  
  { id: 'view_reports', label: 'View Analytics Reports', category: 'Finance' },
  { id: 'view_commissions', label: 'View Commissions', category: 'Finance' },
  { id: 'mark_commissions_paid', label: 'Mark Commissions Paid', category: 'Finance' },
  
  { id: 'view_diagnostics', label: 'View Diagnostics', category: 'System' },
  { id: 'view_audit_trail', label: 'View Audit Trail', category: 'System' },
  { id: 'manage_system', label: 'Manage System & Recovery', category: 'System' },
  
  { id: 'view_all_customers', label: 'Access Full Database (View All)', category: 'Customer Visibility' },
  { id: 'view_own_customers_only', label: 'View Own Records Only (Restricted)', category: 'Customer Visibility' },
];

/**
 * Starting point when a role is picked in the form. Kept in step with
 * grant_role_preset() in supabase/05_seed.sql - if you change one, change both.
 *
 * These are only a suggestion: what actually gets granted is whatever the
 * checkboxes hold when the form is saved, written by set_user_permissions().
 *
 * Super Admin is given every box for clarity in the UI, but has_permission()
 * short-circuits for that role anyway, so the rows are decoration.
 */
const DEFAULT_PERMISSIONS: Record<UserRole, Permission[]> = {
  'Super Admin': PERMISSIONS_LIST.filter(p => p.id !== 'view_own_customers_only').map(p => p.id),
  'Manager': [
    'view_dashboard',
    'view_orders', 'create_orders', 'edit_orders',
    'view_products', 'add_products', 'edit_products',
    'view_inventory', 'adjust_stock',
    'view_customers', 'add_customers', 'edit_customers', 'view_all_customers',
    'view_reports', 'view_commissions', 'mark_commissions_paid',
    'view_audit_trail',
  ],
  'Marketing Officer': [
    'view_dashboard',
    'view_orders', 'create_orders',
    'view_products',
    'add_customers', 'edit_customers', 'view_own_customers_only',
    'view_commissions',
  ],
  'Inventory Staff': [
    'view_dashboard',
    'view_orders',
    'view_products', 'add_products', 'edit_products',
    'view_inventory', 'adjust_stock',
  ],
  'Delivery Staff': [
    'view_dashboard',
    'view_orders', 'edit_orders',
    'view_customers',
  ],
};

export default function UsersPage() {
  const [users, setUsers] = useState<AdminUser[]>([]);
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  // Earned / paid / pending per officer, straight from the ledger view. The old
  // page re-derived these four separate times from the order list.
  const [commissionRows, setCommissionRows] = useState<OfficerCommissionSummaryRow[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [searchTerm, setSearchTerm] = useState("");
  const [isModalOpen, setIsModalOpen] = useState(false);
  const [editingUser, setEditingUser] = useState<AdminUser | null>(null);
  const [notification, setNotification] = useState<{type: 'success' | 'error', message: string} | null>(null);
  const [formData, setFormData] = useState<Omit<AdminUser, 'id' | 'avatar'>>({
    name: "",
    email: "",
    phone: "",
    password: "password123",
    role: "Marketing Officer",
    status: 'active',
    commissionPercentage: 5,
    earnedCommissionTotal: 0,
    pendingCommissionTotal: 0,
    paidCommissionTotal: 0,
    permissions: DEFAULT_PERMISSIONS['Marketing Officer']
  });

  const loadAll = useCallback(async () => {
    const db = getDb();
    const [nextUsers, nextProfile, nextCommissions] = await Promise.all([
      db.users.list(),
      db.auth.getProfile(),
      db.commissions.summary(),
    ]);
    setUsers(nextUsers);
    setCurrentUser(nextProfile);
    setCommissionRows(nextCommissions);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        setIsLoading(true);
        await loadAll();
        if (!cancelled) setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [loadAll]);

  useEffect(() => {
    if (notification) {
      const timer = setTimeout(() => setNotification(null), 3000);
      return () => clearTimeout(timer);
    }
  }, [notification]);

  const perms = derivePermissions(currentUser);

  const showNotification = (type: 'success' | 'error', message: string) => {
    setNotification({ type, message });
  };

  /** Earned / paid / pending for one officer, from the commissions ledger. */
  const commissionsFor = (userId: string) => {
    const row = commissionRows.find(r => r.user_id === userId);
    return {
      earned: Number(row?.earned_commission ?? 0),
      paid: Number(row?.paid_commission ?? 0),
      pending: Number(row?.pending_commission ?? 0),
    };
  };

  if (isLoading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-green" />
        <p className="text-xs font-medium">Loading users…</p>
      </div>
    );
  }

  if (loadError) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-4 py-16 text-center">
          <ShieldAlert className="h-8 w-8 text-red-500" />
          <div>
            <h2 className="font-heading text-lg font-bold text-slate-900">Could not load users</h2>
            <p className="mt-1 max-w-md text-xs text-slate-500">{loadError}</p>
          </div>
          <Button onClick={() => loadAll()} variant="outline" size="sm" className="rounded-lg text-xs">
            <RefreshCcw className="mr-1.5 h-3.5 w-3.5" /> Try again
          </Button>
        </CardContent>
      </Card>
    );
  }

  const handleSaveUser = async (e: React.FormEvent) => {
    e.preventDefault();

    // Clean duplicates and cast numeric types
    const cleanedPermissions = Array.from(new Set(formData.permissions));
    const validatedData = {
      ...formData,
      id: editingUser?.id || "temp-u-id",
      commissionPercentage: Number(formData.commissionPercentage),
      permissions: cleanedPermissions
    };

    const validation = validateUser(validatedData);
    if (!validation.ok) {
      showNotification('error', validation.error || 'Invalid user parameters.');
      return;
    }

    const savedData = {
      ...formData,
      commissionPercentage: Number(formData.commissionPercentage),
      permissions: cleanedPermissions
    };

    try {
      setIsSaving(true);
      const db = getDb();

      if (editingUser) {
        const oldPermissions = editingUser.permissions || [];

        // users.update writes the profile fields and then replaces the whole
        // permission set through set_user_permissions() in one call.
        await db.users.update(editingUser.id, savedData);

        await db.logs.write({
          category: 'SECURITY',
          severity: 'INFO',
          message: `User privileges updated: ${savedData.name} (${savedData.role})`,
          targetId: editingUser.id,
          metadata: {
            oldValue: oldPermissions,
            newValue: savedData.permissions,
            field: 'permissions',
            source: 'Privilege Settings',
          },
        });
      } else {
        const created = await db.users.create({ ...savedData, avatar: "" });

        await db.logs.write({
          category: 'SECURITY',
          severity: 'INFO',
          message: `New user created: ${savedData.name} (${savedData.role})`,
          targetId: created.id,
          metadata: {
            oldValue: [],
            newValue: savedData.permissions,
            field: 'permissions',
            source: 'Privilege Settings',
          },
        });
      }

      await loadAll();
      setIsModalOpen(false);
      showNotification(
        'success',
        editingUser
          ? "User profile updated"
          : "Profile created. Invite them in Supabase Auth with the same email so they can sign in."
      );
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  /**
   * Recomputes every profile's commission totals from the ledger.
   *
   * The old version re-derived them from the order list at today's rate, which
   * silently rewrote history whenever someone's percentage changed. This asks
   * the database to re-add the commission rows that already exist, each with
   * the rate it was earned at.
   */
  const handleRecalculate = async () => {
    try {
      setIsSaving(true);
      const result = await getDb().issues.repair('commission-totals-drift');
      await loadAll();
      showNotification('success', `Commission totals recomputed from the ledger (${result.recordsFixed} profile(s)).`);
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const handlePayout = async (user: AdminUser) => {
    if (!perms.markCommissionsPaid) {
      showNotification('error', 'Permission denied: You are not allowed to mark commissions paid.');
      return;
    }

    try {
      setIsSaving(true);
      const db = getDb();

      // The ledger decides what is owed, not a recalculation from orders.
      const pending = await db.commissions.list({ userId: user.id, status: 'pending' });
      const payoutAmount = pending.reduce((sum, row) => sum + Number(row.amount ?? 0), 0);

      if (payoutAmount < 0.01) {
        showNotification('error', 'No new eligible commissions to pay out.');
        return;
      }

      if (!confirm(`Process commission payout of $${payoutAmount.toFixed(2)} for ${user.name}?\n\n${pending.length} commission(s) will be marked paid and their orders locked.`)) {
        return;
      }

      // One transaction: creates the payout, marks each commission paid, links
      // them to it, and the triggers roll the totals forward.
      const payoutId = await db.commissions.pay(
        user.id,
        pending.map(row => row.id),
        { method: 'Cash' }
      );

      await db.logs.write({
        category: 'FINANCIAL',
        severity: 'INFO',
        message: `Commission payout processed for ${user.name}: $${payoutAmount.toFixed(2)} (${pending.length} commission(s))`,
        targetId: user.id,
        metadata: {
          officerName: user.name,
          amount: payoutAmount,
          commissionCount: pending.length,
          payoutId,
          source: 'Payout Management',
        },
      });

      await loadAll();
      showNotification('success', `Payout of $${payoutAmount.toFixed(2)} processed successfully.`);
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const togglePermission = (perm: Permission) => {
    let newPermissions = [...formData.permissions];
    
    if (newPermissions.includes(perm)) {
      newPermissions = newPermissions.filter(p => p !== perm);
    } else {
      // Mutual exclusivity for Customer Visibility
      if (perm === 'view_all_customers') {
        newPermissions = newPermissions.filter(p => p !== 'view_own_customers_only');
      } else if (perm === 'view_own_customers_only') {
        newPermissions = newPermissions.filter(p => p !== 'view_all_customers');
      }
      newPermissions.push(perm);
    }
    
    setFormData({ ...formData, permissions: newPermissions });
  };

  const handleRoleChange = (role: UserRole) => {
    setFormData({ 
      ...formData, 
      role, 
      permissions: DEFAULT_PERMISSIONS[role] 
    });
  };

  const deleteUser = async (id: string) => {
    const user = users.find(u => u.id === id);
    if (!user) return;

    // Two invariants, checked against the actual data rather than a hardcoded
    // id: you cannot lock yourself out, and the last Super Admin has to stay.
    if (currentUser && currentUser.id === id) {
      showNotification('error', 'You cannot delete your own account.');
      return;
    }

    const remainingSuperAdmins = users.filter(
      u => u.role === 'Super Admin' && u.status === 'active' && u.id !== id
    ).length;

    if (user.role === 'Super Admin' && remainingSuperAdmins === 0) {
      showNotification('error', 'This is the last active Super Admin. Promote someone else first.');
      return;
    }

    if (!confirm(`Permanently remove ${user.name} and all associated privileges?\n\nTheir Supabase Auth account is separate and must be removed there too.`)) {
      return;
    }

    try {
      setIsSaving(true);
      const db = getDb();

      await db.logs.write({
        category: 'SECURITY',
        severity: 'WARNING',
        message: `User deleted: ${user.name}`,
        targetId: id,
        metadata: { role: user.role, email: user.email },
      });

      await db.users.remove(id);
      await loadAll();
      showNotification('success', 'User removed.');
    } catch (error) {
      showNotification('error', describeDbError(error));
    } finally {
      setIsSaving(false);
    }
  };

  const filteredUsers = users.filter(u => 
    u.name.toLowerCase().includes(searchTerm.toLowerCase()) || 
    u.email.toLowerCase().includes(searchTerm.toLowerCase())
  );

  return (
    <div className="space-y-8 animate-in fade-in duration-500">
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="font-heading text-2xl font-bold text-slate-900 tracking-tight">Users & Privileges</h1>
          <p className="text-slate-400 mt-0.5 flex items-center gap-2 text-xs font-medium">
            <ShieldCheck className="h-3.5 w-3.5 text-brand-green" /> 
            Manage administrative access, roles, and commission structures.
          </p>
        </div>
        <div className="flex gap-2">
          {perms.manageSystem && (
            <Button onClick={handleRecalculate} disabled={isSaving} variant="outline" className="text-slate-500 border-slate-200 rounded-lg h-10 px-4 text-xs">
              <RefreshCcw className={cn("h-3.5 w-3.5 mr-1.5", isSaving && "animate-spin")} /> Recalculate Commissions
            </Button>
          )}
          {perms.manageUsers && (
            <Button onClick={() => { setEditingUser(null); setIsModalOpen(true); }} disabled={isSaving} className="bg-slate-900 text-white rounded-lg h-10 px-4 text-xs shadow-lg shadow-slate-200">
              <Plus className="h-4 w-4 mr-1" /> Add New Member
            </Button>
          )}
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-4 gap-4">
        <Card className="border-none shadow-sm bg-blue-50/40">
          <CardContent className="p-4">
            <p className="text-[9px] font-bold text-blue-600 uppercase tracking-widest mb-0.5">Total Staff</p>
            <h3 className="text-xl font-bold text-slate-900">{users.length}</h3>
          </CardContent>
        </Card>
        <Card className="border-none shadow-sm bg-green-50/40">
          <CardContent className="p-4">
            <p className="text-[9px] font-bold text-brand-green uppercase tracking-widest mb-0.5">Active Roles</p>
            <h3 className="text-xl font-bold text-slate-900">{new Set(users.map(u => u.role)).size}</h3>
          </CardContent>
        </Card>
        <Card className="border-none shadow-sm bg-amber-50/40">
          <CardContent className="p-4">
            <p className="text-[9px] font-bold text-amber-600 uppercase tracking-widest mb-0.5">Marketing Officers</p>
            <h3 className="text-xl font-bold text-slate-900">{users.filter(u => u.role === 'Marketing Officer').length}</h3>
          </CardContent>
        </Card>
        <Card className="border-none shadow-sm bg-red-50/40">
          <CardContent className="p-4">
            <p className="text-[9px] font-bold text-red-600 uppercase tracking-widest mb-0.5">System Admins</p>
            <h3 className="text-xl font-bold text-slate-900">{users.filter(u => u.role === 'Super Admin').length}</h3>
          </CardContent>
        </Card>
      </div>

      <Card className="border-none shadow-sm overflow-hidden">
        <div className="p-4 border-b flex flex-col md:flex-row gap-3 items-center justify-between bg-white">
          <div className="relative w-full md:w-80">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400" />
            <Input 
              placeholder="Search by name or email..." 
              className="pl-9 h-9 bg-slate-50 border-none rounded-lg text-xs"
              value={searchTerm}
              onChange={e => setSearchTerm(e.target.value)}
            />
          </div>
          <div className="flex gap-2">
            <Button variant="outline" size="sm" className="rounded-lg border-slate-200 text-xs h-9">
              <Filter className="h-3.5 w-3.5 mr-1.5" /> Filters
            </Button>
          </div>
        </div>
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="text-[9px] text-slate-400 uppercase font-bold tracking-widest bg-slate-50/50 border-b border-slate-100">
                <tr>
                  <th className="px-6 py-3">Administrator</th>
                  <th className="px-6 py-3">Security Role</th>
                  <th className="px-6 py-3">Status</th>
                  <th className="px-6 py-3">Commission</th>
                  <th className="px-6 py-3 text-right">Actions</th>
                </tr>
              </thead>
              <tbody>
                {filteredUsers.map((user) => (
                  <tr key={user.id} className="hover:bg-slate-50/30 transition-colors group border-b border-slate-50/50 last:border-0">
                    <td className="px-6 py-3">
                      <div className="flex items-center gap-2.5">
                        <div className="h-8 w-8 rounded-lg bg-slate-100 flex items-center justify-center text-slate-400 overflow-hidden shrink-0">
                          {user.avatar ? <img src={user.avatar} className="h-full w-full object-cover" /> : <User className="h-4 w-4" />}
                        </div>
                        <div className="min-w-0">
                          <p className="font-bold text-slate-900 truncate">{user.name}</p>
                          <p className="text-[10px] text-slate-500 font-medium truncate">{user.email}</p>
                        </div>
                      </div>
                    </td>
                    <td className="px-6 py-3">
                      <div className="inline-flex items-center gap-1 px-2 py-0.5 bg-slate-100 text-slate-600 rounded text-[9px] font-bold uppercase tracking-wider">
                        <Shield className="h-2.5 w-2.5" />
                        {user.role}
                      </div>
                    </td>
                    <td className="px-6 py-3">
                      <div className={cn(
                        "inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-[9px] font-bold uppercase",
                        user.status === 'active' ? "bg-green-50 text-green-600" : "bg-red-50 text-red-600"
                      )}>
                        {user.status === 'active' ? <CheckCircle className="h-2.5 w-2.5" /> : <XCircle className="h-2.5 w-2.5" />}
                        {user.status}
                      </div>
                    </td>
                    <td className="px-6 py-3">
                      <div className="flex flex-col gap-0.5">
                        <div className="flex items-center gap-1.5">
                          <span className="font-bold text-slate-900">{user.commissionPercentage}%</span>
                          <span className="text-[9px] text-slate-400 font-medium uppercase tracking-tighter">Rate</span>
                        </div>
                        {user.role === 'Marketing Officer' && (() => {
                          const { earned, paid, pending } = commissionsFor(user.id);

                          return (
                            <div className="flex items-center gap-2 mt-0.5 overflow-hidden">
                              <p className="text-[9px] text-brand-green font-bold whitespace-nowrap">E: ${earned.toFixed(0)}</p>
                              <p className="text-[9px] text-blue-600 font-bold whitespace-nowrap">P: ${paid.toFixed(0)}</p>
                              {pending > 0.01 && <p className="text-[9px] text-orange-600 font-bold animate-pulse whitespace-nowrap">D: ${pending.toFixed(0)}</p>}
                            </div>
                          );
                        })()}
                      </div>
                    </td>
                    <td className="px-6 py-3 text-right">
                      <div className="flex justify-end gap-1.5">
                        {perms.markCommissionsPaid && user.role === 'Marketing Officer' && (() => {
                          const pendingPayout = commissionsFor(user.id).pending;
                          const isButtonDisabled = pendingPayout < 0.01 || isSaving;

                          return (
                            <Button
                              onClick={() => handlePayout(user)}
                              disabled={isButtonDisabled}
                              variant="outline"
                              size="sm"
                              className={cn(
                                "h-7 px-2 text-[9px] font-bold uppercase rounded-md transition-all shadow-sm",
                                !isButtonDisabled
                                  ? "text-brand-green border-brand-green bg-green-50/50 hover:bg-green-100"
                                  : "text-slate-300 border-slate-100 opacity-50 cursor-not-allowed"
                              )}
                            >
                              Payout {pendingPayout > 0.01 ? `($${pendingPayout.toFixed(0)})` : ''}
                            </Button>
                          );
                        })()}
                        <Button onClick={() => { setEditingUser(user); setFormData(user); setIsModalOpen(true); }} disabled={isSaving} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-brand-blue hover:bg-blue-50 rounded-md">
                          <Edit className="h-3.5 w-3.5" />
                        </Button>
                        <Button onClick={() => deleteUser(user.id)} disabled={isSaving} variant="ghost" size="sm" className="h-7 w-7 p-0 text-slate-400 hover:text-red-600 hover:bg-red-50 rounded-md">
                          <Trash2 className="h-3.5 w-3.5" />
                        </Button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>

      {/* User Management Modal */}
      {isModalOpen && (
        <div className="fixed inset-0 z-[100] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white rounded-[1.5rem] shadow-2xl w-full max-w-3xl max-h-[90vh] overflow-hidden flex flex-col animate-in zoom-in duration-300">
            <div className="p-6 border-b flex justify-between items-center bg-white sticky top-0 z-10 shrink-0">
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 bg-brand-blue/10 rounded-xl flex items-center justify-center text-brand-blue shadow-inner">
                  <UserPlus className="h-5 w-5" />
                </div>
                <div>
                  <h2 className="text-lg font-bold text-slate-900 tracking-tight">{editingUser ? 'Refine Privileges' : 'Onboard New Member'}</h2>
                  <p className="text-slate-500 text-[11px] font-medium">Define identity and security scope.</p>
                </div>
              </div>
              <button onClick={() => setIsModalOpen(false)} className="h-8 w-8 hover:bg-slate-100 rounded-full transition-colors flex items-center justify-center border border-slate-100">
                <X className="h-4 w-4 text-slate-400" />
              </button>
            </div>

            <div className="flex-1 overflow-y-auto p-6 custom-scrollbar">
              <form id="user-form" onSubmit={handleSaveUser} className="space-y-8">
                <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
                  <div className="space-y-6">
                    <h3 className="text-[10px] font-bold text-slate-400 uppercase tracking-widest flex items-center gap-2">
                      <UserCheck className="h-3.5 w-3.5" /> Identity & Contact
                    </h3>
                    <div className="space-y-3 bg-slate-50/50 p-4 rounded-2xl border border-slate-100 shadow-inner">
                      <div className="space-y-1">
                        <label className="text-[10px] font-bold text-slate-700 ml-1">Full Display Name</label>
                        <Input required value={formData.name} onChange={e => setFormData({...formData, name: e.target.value})} className="bg-white border-slate-200 h-9 text-xs" placeholder="e.g., Abdullahi Ahmed" />
                      </div>
                      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                        <div className="space-y-1">
                          <label className="text-[10px] font-bold text-slate-700 ml-1">Work Email</label>
                          <Input type="email" required value={formData.email} onChange={e => setFormData({...formData, email: e.target.value})} className="bg-white border-slate-200 h-9 text-xs" placeholder="admin@efz.so" />
                        </div>
                        <div className="space-y-1">
                          <label className="text-[10px] font-bold text-slate-700 ml-1">Phone Number</label>
                          <Input required value={formData.phone} onChange={e => setFormData({...formData, phone: e.target.value})} className="bg-white border-slate-200 h-9 text-xs" placeholder="+252 61..." />
                        </div>
                      </div>

                      {/* No password field: credentials live in Supabase Auth and
                          never reach this database. A box here would look like it
                          set something and quietly do nothing. */}
                      <div className="mt-3 flex items-start gap-2 rounded-xl border border-blue-100 bg-blue-50/60 p-3">
                        <Info className="mt-0.5 h-3.5 w-3.5 shrink-0 text-brand-blue" />
                        <p className="text-[10px] font-medium leading-relaxed text-slate-600">
                          Passwords are handled by Supabase Auth, not here. After saving,
                          invite this person under <span className="font-bold">Authentication &rarr; Users</span> using
                          the same email and their profile links automatically.
                        </p>
                      </div>
                    </div>

                    <h3 className="text-[10px] font-bold text-slate-400 uppercase tracking-widest flex items-center gap-2 pt-2">
                      <Shield className="h-3.5 w-3.5" /> Security Assignment
                    </h3>
                    <div className="space-y-3 bg-slate-50/50 p-4 rounded-2xl border border-slate-100 shadow-inner">
                      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                        <div className="space-y-1">
                          <label className="text-[10px] font-bold text-slate-700 ml-1">System Role</label>
                          <select 
                            className="w-full h-9 rounded-lg border border-slate-200 bg-white px-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all"
                            value={formData.role}
                            onChange={e => handleRoleChange(e.target.value as UserRole)}
                          >
                            {ROLES.map(r => <option key={r} value={r}>{r}</option>)}
                          </select>
                        </div>
                        <div className="space-y-1">
                          <label className="text-[10px] font-bold text-slate-700 ml-1">Account Status</label>
                          <select 
                            className="w-full h-9 rounded-lg border border-slate-200 bg-white px-3 text-xs font-medium outline-none focus:ring-2 focus:ring-brand-blue/20 transition-all"
                            value={formData.status}
                            onChange={e => setFormData({...formData, status: e.target.value as AdminUser["status"]})}
                          >
                            <option value="active">Active Access</option>
                            <option value="inactive">Suspended</option>
                          </select>
                        </div>
                      </div>
                      <div className="space-y-1">
                        <label className="text-[10px] font-bold text-slate-700 ml-1 flex items-center justify-between">
                          Commission Rate (%)
                          <span className="text-[9px] text-blue-600 font-bold px-1.5 py-0.5 bg-blue-50 rounded uppercase">Sales Only</span>
                        </label>
                        <div className="relative">
                          <DollarSign className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-slate-400" />
                          <Input type="number" value={formData.commissionPercentage} onChange={e => setFormData({...formData, commissionPercentage: parseFloat(e.target.value) || 0})} className="bg-white border-slate-200 h-9 pl-9 text-xs" />
                        </div>
                      </div>
                    </div>
                  </div>

                  {/* Permissions Section */}
                  <div className="flex flex-col h-full">
                    <h3 className="text-[10px] font-bold text-slate-400 uppercase tracking-widest flex items-center gap-2 mb-4">
                      <ShieldAlert className="h-3.5 w-3.5" /> Scope of Privileges
                    </h3>
                    <div className="flex-1 bg-slate-900 rounded-2xl p-6 text-slate-300 overflow-y-auto max-h-[400px] shadow-2xl custom-scrollbar border border-slate-800">
                      <p className="text-[9px] font-bold text-slate-500 uppercase tracking-[0.2em] mb-4 border-b border-slate-800 pb-1.5">Manual Override</p>
                      
                      {['General', 'Inventory', 'Orders', 'CRM', 'Customer Visibility', 'Finance'].map(category => (
                        <div key={category} className="mb-6">
                          <h4 className="text-[10px] font-bold text-brand-green uppercase tracking-wider mb-3 opacity-80">{category}</h4>
                          <div className="space-y-2">
                            {PERMISSIONS_LIST.filter(p => p.category === category).map(p => (
                              <label 
                                key={p.id} 
                                className="flex items-center gap-2.5 group cursor-pointer"
                                onClick={(e) => {
                                  e.preventDefault();
                                  togglePermission(p.id);
                                }}
                              >
                                <div 
                                  className={cn(
                                    "h-4 w-4 rounded bg-slate-800 border flex items-center justify-center transition-all",
                                    formData.permissions.includes(p.id) 
                                      ? "bg-brand-green border-brand-green" 
                                      : "border-slate-700 group-hover:border-slate-500"
                                  )}
                                >
                                  {formData.permissions.includes(p.id) && <ShieldCheck className="h-3 w-3 text-slate-900" />}
                                </div>
                                <span className={cn(
                                  "text-[12px] font-medium transition-colors",
                                  formData.permissions.includes(p.id) ? "text-slate-100" : "text-slate-500 group-hover:text-slate-300"
                                )}>
                                  {p.label}
                                </span>
                              </label>
                            ))}
                          </div>
                        </div>
                      ))}
                    </div>
                  </div>
                </div>
              </form>
            </div>
 
            <div className="p-6 border-t bg-slate-50/50 flex gap-3 shrink-0">
              <Button type="submit" form="user-form" disabled={isSaving} className="flex-1 bg-slate-900 text-white h-11 rounded-xl font-bold text-sm hover:bg-slate-800 transition-all shadow-lg shadow-slate-200">
                {isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                {editingUser ? 'Save Privilege Updates' : 'Confirm & Grant Access'}
              </Button>
              <Button variant="outline" disabled={isSaving} onClick={() => setIsModalOpen(false)} className="px-8 h-11 rounded-xl font-bold text-xs text-slate-500 hover:bg-white border-slate-200">
                Cancel
              </Button>
            </div>
          </div>
        </div>
      )}
      {/* Global Notification Toast */}
      {notification && (
        <div className={cn(
          "fixed bottom-8 right-8 z-[200] flex items-center gap-3 px-6 py-4 rounded-2xl shadow-2xl border animate-in slide-in-from-right-10 duration-300",
          notification.type === 'success' ? "bg-white border-green-100 text-slate-900" : "bg-red-50 border-red-100 text-red-900"
        )}>
          <div className={cn(
            "h-8 w-8 rounded-full flex items-center justify-center shrink-0",
            notification.type === 'success' ? "bg-green-100 text-green-600" : "bg-red-100 text-red-600"
          )}>
            {notification.type === 'success' ? <CheckCircle className="h-4 w-4" /> : <ShieldAlert className="h-4 w-4" />}
          </div>
          <p className="text-sm font-bold pr-2">{notification.message}</p>
        </div>
      )}
    </div>
  );
}
