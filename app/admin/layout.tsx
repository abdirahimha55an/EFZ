"use client";

import { useState, useEffect, useRef } from "react";
import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { 
  LayoutDashboard, 
  ShoppingBag, 
  Package, 
  BarChart3,
  LogOut, 
  Menu, 
  X, 
  Search, 
  Bell, 
  User, 
  Users,
  Settings as SettingsIcon,
  ShieldCheck,
  ExternalLink,
  ChevronDown,
  Mail,
  Smartphone,
  Globe,
  Plus,
  ArrowRight,
  Info,
  Image as ImageIcon,
  Upload,
  Lock,
  UserCheck,
  Database,
  Download,
  History,
  Clock,
  Sun,
  Moon,
  Wallet
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { AdminSettings, AdminProfile, Notification, Order, Permission, Product } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { getSupabaseBrowserClient } from "@/lib/supabase/client";
import { derivePermissions, hasPermission as can, hasAnyPermission as canAny } from "@/lib/permissions";
import { SystemStatusBadge } from "@/components/admin/SystemStatusBadge";

// Shown until the real row arrives, so the chrome never renders blank.
const DEFAULT_SETTINGS: AdminSettings = {
  businessName: "Elite Football Zone",
  shortName: "EFZ",
  logo: "",
  favicon: "",
  whatsappNumber: "",
  contactEmail: "",
  defaultLowStockThreshold: 50,
  currencySymbol: "$",
  theme: "light",
  primaryColor: "#0F172A",
  secondaryColor: "#00E676",
};

const SIDEBAR_LINKS = [
  { name: "Overview", href: "/admin", icon: LayoutDashboard, permission: 'view_dashboard' as Permission },
  { name: "Order Tracking", href: "/admin/orders", icon: ShoppingBag, permission: 'view_orders' as Permission },
  { name: "Sales & Analytics", href: "/admin/analytics", icon: BarChart3, permission: 'view_reports' as Permission },
  { name: "Inventory Control", href: "/admin/products", icon: Package, permission: 'view_products' as Permission },
  { name: "Customer Database", href: "/admin/customers", icon: UserCheck, permission: 'view_customers' as Permission },
  // A Marketing Officer's own commission events (read only). Shown to officers only.
  { name: "My Commissions", href: "/admin/commissions", icon: Wallet, permission: 'view_commissions' as Permission },
  { name: "Users & Privileges", href: "/admin/users", icon: Users, permission: 'manage_users' as Permission },
];

const SYSTEM_LINKS = [
  { name: "Diagnostics", href: "/admin/diagnostics", icon: ShieldCheck, permission: 'view_diagnostics' as Permission },
  { name: "Audit Trail", href: "/admin/audit", icon: History, permission: 'view_audit_trail' as Permission },
  { name: "System Management", href: "/admin/system", icon: SettingsIcon, permission: 'manage_system' as Permission },
];

/** How often an open admin tab re-derives its alerts (also when the tab regains focus). */
const ALERT_REFRESH_MS = 30_000;

/** A burst of Realtime order changes (e.g. an order and its status update) becomes one refresh. */
const ALERT_SIGNAL_DEBOUNCE_MS = 300;

/** Realtime channel topic prefix for the "an order I can see changed" signal. */
const ORDER_ALERT_TOPIC = "order-alerts";

/** Pending-order alerts are personal: one row per user, `order-<orderId>@<profileId>`. */
const personalOrderAlertId = (orderId: string, profileId: string) => `order-${orderId}@${profileId}`;

/**
 * Order alerts written before they became personal were shared rows `order-<orderId>`
 * (no "@") that every staff member could read, whoever's order it was. Not shown.
 */
const isLegacySharedOrderAlert = (n: Notification) => n.id.startsWith("order-") && !n.id.includes("@");

/**
 * Derives the alert feed from live data and stores any new alerts:
 * - low/out-of-stock alerts are shared by all staff (stable ids `low-…` / `out-…`);
 * - "New Order" alerts are personal: only for pending orders this user may see (the
 *   orders list is RLS-scoped) and stored with user_id = this user, so RLS shows each
 *   user their own alerts and read/unread is per user.
 * Ids are stable and the upsert ignores duplicates, so repeating this never creates
 * copies and an alert already read stays read. Returns the feed, newest first.
 */
async function loadAlertFeed(db: ReturnType<typeof getDb>, me: AdminProfile, defaultThreshold: number): Promise<Notification[]> {
  const [products, orders, existing] = await Promise.all([
    db.products.list(),
    db.orders.list({ limit: 200 }),
    db.notifications.list(),
  ]);

  const derived: Array<Pick<Notification, "id" | "title" | "message" | "type"> & { userId?: string }> = [];

  products.forEach(p => {
    if (p.stock === 0) {
      derived.push({ id: `out-${p.id}`, title: "Out of Stock", message: `${p.name} is out of stock!`, type: 'stock' });
    } else if (p.stock <= (p.lowStockThreshold || defaultThreshold)) {
      derived.push({ id: `low-${p.id}`, title: "Low Stock Alert", message: `${p.name} is low (${p.stock}).`, type: 'stock' });
    }
  });

  orders.forEach(o => {
    if (o.status === 'pending') {
      derived.push({ id: personalOrderAlertId(o.id, me.id), title: "New Order", message: `Order from ${o.customer} pending.`, type: 'order', userId: me.id });
    }
  });

  const unseen = derived.filter(alert => !existing.some(n => n.id === alert.id));
  if (unseen.length > 0) {
    await db.notifications.upsertAlerts(unseen);
  }

  const merged = unseen.length > 0 ? await db.notifications.list() : existing;
  return merged
    .filter(n => !isLegacySharedOrderAlert(n))
    .sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime());
}

export default function AdminLayout({ children }: { children: React.ReactNode }) {
  const pathname = usePathname();
  const router = useRouter();
  const [isMounted, setIsMounted] = useState(false);
  const [isMobileOpen, setIsMobileOpen] = useState(false);
  const [isProfileOpen, setIsProfileOpen] = useState(false);
  const [isNotificationsOpen, setIsNotificationsOpen] = useState(false);
  const [isSettingsOpen, setIsSettingsOpen] = useState(false);
  const [isSearchOpen, setIsSearchOpen] = useState(false);
  
  const [searchQuery, setSearchQuery] = useState("");
  const [searchResults, setSearchResults] = useState<{products: Product[], orders: Order[]}>({ products: [], orders: [] });
  const [theme, setTheme] = useState<'light' | 'dark'>('light');

  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [settings, setSettings] = useState<AdminSettings>(DEFAULT_SETTINGS);
  const [notifications, setNotifications] = useState<Notification[]>([]);
  const [toast, setToast] = useState<{ type: 'success' | 'error', message: string } | null>(null);
  const [dataCounts, setDataCounts] = useState<Record<string, number>>({});
  const [lastBackupAt, setLastBackupAt] = useState<string | null>(null);
  const [isBackingUp, setIsBackingUp] = useState(false);

  const profileRef = useRef<HTMLDivElement>(null);
  const notificationsRef = useRef<HTMLDivElement>(null);
  const searchRef = useRef<HTMLDivElement>(null);
  const avatarInputRef = useRef<HTMLInputElement>(null);

  const isLoginPage = pathname === "/admin/login";

  // Load the chrome: who is signed in, the branding, and the alert feed.
  useEffect(() => {
    // The login page renders without the chrome, so there is nothing to load.
    if (isLoginPage) return;

    let cancelled = false;

    (async () => {
      // The layout outlives /admin/login, so drop whoever was signed in before:
      // their alerts must not show, or be refreshed, under the next sign-in.
      setProfile(null);
      setNotifications([]);
      try {
        const db = getDb();
        const nextProfile = await db.auth.getProfile();

        if (cancelled) return;

        // proxy.ts already bounces signed-out visitors; this catches the case
        // where the session is valid but no staff profile is linked to it.
        if (!nextProfile) {
          await db.auth.logout();
          router.replace("/admin/login");
          return;
        }

        setProfile(nextProfile);

        const nextSettings = await db.settings.get();
        if (cancelled) return;

        setSettings(nextSettings);
        setTheme(nextSettings.theme || 'light');

        const feed = await loadAlertFeed(db, nextProfile, nextSettings.defaultLowStockThreshold);
        if (cancelled) return;

        setNotifications(feed);
      } catch (error) {
        if (!cancelled) console.error("[ADMIN LAYOUT] Failed to load:", describeDbError(error));
      } finally {
        if (!cancelled) setIsMounted(true);
      }
    })();

    return () => {
      cancelled = true;
    };
    // Deliberately not keyed on pathname: the layout survives navigation
    // between admin routes, so re-running this would refetch the whole catalog
    // and order list on every click for nothing.
  }, [isLoginPage, router]);

  // Keep the alert feed live while the app is open: re-derive at once when
  // Realtime reports a change to an order this user may read, every
  // ALERT_REFRESH_MS as the fallback, and whenever the tab becomes visible /
  // regains focus, so a new pending order shows up without a page refresh. One
  // loop and one channel per signed-in user (keyed on the profile id only, so
  // navigation and unrelated state do not restart it); runs never overlap, a
  // request made during a run is replayed once it ends, a hidden tab does not
  // refresh, and everything is torn down on unmount, logout or when the user
  // changes.
  const alertProfileRef = useRef<AdminProfile | null>(null);
  const alertThresholdRef = useRef(DEFAULT_SETTINGS.defaultLowStockThreshold);
  useEffect(() => { alertProfileRef.current = profile; }, [profile]);
  useEffect(() => { alertThresholdRef.current = settings.defaultLowStockThreshold; }, [settings.defaultLowStockThreshold]);
  const alertProfileId = profile?.id ?? null;
  useEffect(() => {
    if (isLoginPage || !alertProfileId) return;

    let stopped = false;
    let running = false;
    // Set when a refresh is asked for while one is running: that run may have
    // read the orders before the change committed, so it must not be dropped.
    let again = false;
    let signalTimer: number | undefined;
    const supabase = getSupabaseBrowserClient();

    const refresh = async () => {
      if (running) {
        again = true;
        return;
      }
      running = true;
      try {
        do {
          again = false;
          const me = alertProfileRef.current;
          if (stopped || !me || document.visibilityState === "hidden") break;
          try {
            // The session can change under an open tab (logout and sign-in as
            // someone else, here or in another tab). Derive alerts for `me` only
            // while the database still sees `me` signed in: a session holding
            // manage_system could otherwise store `me` alerts for orders `me`
            // may not see.
            const { data: signedInId, error: whoError } = await supabase.rpc("current_profile_id");
            if (whoError) throw whoError;
            if (signedInId !== me.id) break;
            const feed = await loadAlertFeed(getDb(), me, alertThresholdRef.current);
            if (!stopped) setNotifications(feed);
          } catch (error) {
            if (!stopped) console.error("[ADMIN LAYOUT] Alert refresh failed:", describeDbError(error));
          }
        } while (again && !stopped);
      } finally {
        running = false;
      }
    };

    const onVisible = () => {
      if (document.visibilityState === "visible") void refresh();
    };

    // Realtime (migration 15): an INSERT/UPDATE of an order reaches this tab only
    // if this user's own JWT passes the orders SELECT policy. The event is just a
    // "refresh now" signal - the payload is never read and no notification is
    // written from it; loadAlertFeed derives and stores alerts exactly as the
    // polling does (same ids, duplicates ignored). DELETE is not subscribed to.
    const onOrderChange = () => {
      window.clearTimeout(signalTimer);
      signalTimer = window.setTimeout(() => void refresh(), ALERT_SIGNAL_DEBOUNCE_MS);
    };

    // One channel per tab: drop any left over from an earlier user or mount.
    // Each mount gets its own topic, so it never reuses a channel still closing.
    supabase.getChannels()
      .filter(c => c.topic.startsWith(`realtime:${ORDER_ALERT_TOPIC}:`))
      .forEach(c => void supabase.removeChannel(c));
    const channel = supabase
      .channel(`${ORDER_ALERT_TOPIC}:${alertProfileId}:${Date.now().toString(36)}`)
      .on("postgres_changes", { event: "INSERT", schema: "public", table: "orders" }, onOrderChange)
      .on("postgres_changes", { event: "UPDATE", schema: "public", table: "orders" }, onOrderChange)
      .subscribe(status => {
        // Changes made while the channel was down are not replayed: catch up on
        // every (re)join. Errors need nothing here - the client rejoins by
        // itself and the timer below keeps refreshing meanwhile.
        if (status === "SUBSCRIBED") onOrderChange();
      });

    const timer = window.setInterval(() => void refresh(), ALERT_REFRESH_MS);
    document.addEventListener("visibilitychange", onVisible);
    window.addEventListener("focus", onVisible);

    return () => {
      stopped = true;
      window.clearInterval(timer);
      window.clearTimeout(signalTimer);
      document.removeEventListener("visibilitychange", onVisible);
      window.removeEventListener("focus", onVisible);
      void supabase.removeChannel(channel);
    };
  }, [isLoginPage, alertProfileId]);

  // Click-outside listeners for the header dropdowns.
  useEffect(() => {
    const handleClickOutside = (event: MouseEvent) => {
      if (profileRef.current && !profileRef.current.contains(event.target as Node)) setIsProfileOpen(false);
      if (notificationsRef.current && !notificationsRef.current.contains(event.target as Node)) setIsNotificationsOpen(false);
      if (searchRef.current && !searchRef.current.contains(event.target as Node)) setIsSearchOpen(false);
    };

    document.addEventListener("mousedown", handleClickOutside);
    return () => document.removeEventListener("mousedown", handleClickOutside);
  }, []);

  // Row counts for the System Management panel, fetched only when it opens -
  // and only for users who may manage the system (backups are manage_system in RLS).
  useEffect(() => {
    if (!isSettingsOpen || !can(profile, "manage_system")) return;

    let cancelled = false;

    (async () => {
      try {
        const db = getDb();
        const [counts, snapshots] = await Promise.all([
          db.analytics.dataCounts(),
          db.backups.list(),
        ]);
        if (cancelled) return;
        setDataCounts(counts);
        setLastBackupAt(snapshots[0]?.created_at ?? null);
      } catch {
        if (!cancelled) setDataCounts({});
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [isSettingsOpen, profile]);

  // Handle Theme Application
  useEffect(() => {
    if (isMounted) {
      const root = window.document.documentElement;
      if (theme === 'dark') {
        root.classList.add('dark');
      } else {
        root.classList.remove('dark');
      }
    }
  }, [theme, isMounted]);

  // Derived state
  const unreadCount = notifications.filter(n => !n.read).length;
  const perms = derivePermissions(profile);

  const hasPermission = (p: Permission) => can(profile, p);
  const hasAnyPermission = (permissions: Permission[]) => canAny(profile, permissions);

  const currentLink = SIDEBAR_LINKS.find(link => link.href === pathname) || SYSTEM_LINKS.find(link => link.href === pathname);

  let isAccessDenied = false;
  if (currentLink) {
    if (currentLink.href === '/admin/customers') {
      isAccessDenied = !perms.accessCustomerModule;
    } else if (currentLink.href === '/admin/orders') {
      isAccessDenied = !perms.accessOrdersModule;
    } else {
      isAccessDenied = !can(profile, currentLink.permission);
    }
  }

  // Loading state (moved after all hooks)
  if ((!isMounted || !profile) && !isLoginPage) {
    return (
      <div className="min-h-screen bg-slate-50 flex items-center justify-center">
        <div className="w-8 h-8 border-4 border-brand-blue border-t-transparent rounded-full animate-spin"></div>
      </div>
    );
  }

  // Handle Login Page separately
  if (isLoginPage) {
    return <>{children}</>;
  }

  // Unreachable - the loading guard above already returns when profile is null.
  // Present so the rest of this component can treat it as loaded.
  if (!profile) return null;

  const showToast = (type: 'success' | 'error', message: string) => {
    setToast({ type, message });
    setTimeout(() => setToast(null), 3000);
  };

  // Searches the database rather than an in-memory copy, so results reflect what
  // the user is actually allowed to see - RLS filters the rows server-side.
  const handleSearch = async (q: string) => {
    setSearchQuery(q);
    if (q.length < 2) {
      setSearchResults({ products: [], orders: [] });
      setIsSearchOpen(false);
      return;
    }

    try {
      const db = getDb();
      const [allProducts, allOrders] = await Promise.all([
        db.products.list(),
        db.orders.list({ limit: 200 }),
      ]);

      const needle = q.toLowerCase();

      const products = allProducts
        .filter(p => p.name.toLowerCase().includes(needle) || p.category.toLowerCase().includes(needle))
        .slice(0, 4);

      const orders = allOrders.filter(o => {
        const haystack = [
          o.customer,
          o.id,
          o.legacyReferenceId,
          ...(o.legacyOrderIds || [])
        ].filter(Boolean).join(" ").toLowerCase();
        return haystack.includes(needle);
      }).slice(0, 4);

      setSearchResults({ products, orders });
      setIsSearchOpen(true);
    } catch (error) {
      showToast('error', describeDbError(error));
    }
  };

  const handleLogout = async () => {
    try {
      const db = getDb();
      // Logged while still authenticated - after signOut the insert policy
      // would reject it.
      await db.logs.write({
        category: 'SECURITY',
        severity: 'INFO',
        message: 'User logged out of the system',
      });
      await db.auth.logout();
    } catch {
      // Never trap someone in the app because the log write failed.
    } finally {
      router.replace("/admin/login");
      router.refresh();
    }
  };

  const saveProfile = async (e: React.FormEvent) => {
    e.preventDefault();

    // Validation
    if (profile.name.trim().length < 2) {
      showToast('error', 'Display name is too short');
      return;
    }
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(profile.email)) {
      showToast('error', 'Invalid email address format');
      return;
    }

    try {
      const db = getDb();
      const updated = await db.users.update(profile.id, {
        name: profile.name,
        email: profile.email,
        phone: profile.phone,
        avatar: profile.avatar,
      });
      setProfile(updated);

      await db.logs.write({
        category: 'SECURITY',
        severity: 'INFO',
        message: 'Admin profile identity updated',
        targetId: profile.id,
      });
      showToast('success', 'Profile identity updated successfully');
    } catch (error) {
      showToast('error', describeDbError(error));
    }
  };

  const saveSettings = async (e: React.FormEvent) => {
    e.preventDefault();

    // Company settings are Super Admin only - the role, not a grantable
    // permission. The database refuses anyone else too (RLS settings_update =
    // is_super_admin(), migration 14); this just says so before trying.
    if (!perms.isSuperAdmin) {
      showToast('error', 'Only a Super Admin can change company settings.');
      return;
    }

    try {
      const db = getDb();
      const saved = await db.settings.update(settings);
      setSettings(saved);
      setTheme(saved.theme || 'light');

      await db.logs.write({
        category: 'SYSTEM',
        severity: 'INFO',
        message: 'Global system settings modified',
      });
      showToast('success', 'System settings saved successfully');
    } catch (error) {
      showToast('error', describeDbError(error));
    }
  };

  const toggleTheme = async () => {
    const newTheme = theme === 'light' ? 'dark' : 'light';
    setTheme(newTheme);   // applied immediately; persistence follows

    // Theme is a shared company setting: anyone but the Super Admin flips it
    // for this visit only and does not try to save it for everyone.
    if (!perms.isSuperAdmin) return;

    try {
      const db = getDb();
      await db.settings.update({ theme: newTheme });
      await db.logs.write({
        category: 'SYSTEM',
        severity: 'INFO',
        message: `User switched theme to ${newTheme} mode`,
      });
    } catch (error) {
      // Theme is a shared setting: only the Super Admin can save it for everyone.
      showToast('error', describeDbError(error));
    }
  };

  /**
   * Snapshots the core tables into a `backups` row, then hands the same payload
   * to the browser as a download. The stored row is the copy that survives a
   * lost laptop; the file is the copy you can hold on to.
   */
  const handleExportBackup = async () => {
    setIsBackingUp(true);
    let url: string | null = null;
    const link = document.createElement('a');

    try {
      const db = getDb();
      const snapshot = await db.backups.create(
        `Manual export by ${profile.name} on ${new Date().toISOString().slice(0, 10)}`
      );

      const stored = await db.backups.list();
      setLastBackupAt(stored[0]?.created_at ?? null);

      const blob = new Blob([JSON.stringify(snapshot, null, 2)], { type: 'application/json' });
      url = URL.createObjectURL(blob);
      link.href = url;
      link.download = `efz_backup_${new Date().toISOString().split('T')[0]}.json`;
      document.body.appendChild(link);
      link.click();

      showToast('success', 'Snapshot saved and download started.');
    } catch (error) {
      showToast('error', describeDbError(error));
    } finally {
      if (link.parentNode) link.parentNode.removeChild(link);
      if (url) URL.revokeObjectURL(url);
      setIsBackingUp(false);
    }
  };

  const handleRefreshBackups = async () => {
    try {
      const db = getDb();
      const [counts, snapshots] = await Promise.all([
        db.analytics.dataCounts(),
        db.backups.list(),
      ]);
      setDataCounts(counts);
      setLastBackupAt(snapshots[0]?.created_at ?? null);
      showToast('success', 'Snapshot list refreshed');
    } catch (error) {
      showToast('error', describeDbError(error));
    }
  };

  const markAllRead = async () => {
    const previous = notifications;
    setNotifications(notifications.map(n => ({ ...n, read: true })));

    try {
      await getDb().notifications.markAllRead();
    } catch (error) {
      setNotifications(previous);
      showToast('error', describeDbError(error));
    }
  };

  const clearNotifications = async () => {
    const previous = notifications;
    setNotifications([]);

    try {
      await getDb().notifications.clearAll();
    } catch (error) {
      setNotifications(previous);
      showToast('error', describeDbError(error));
    }
  };

  return (
    <div className="flex h-screen bg-slate-50 dark:bg-slate-950 font-sans selection:bg-brand-blue/10 overflow-hidden text-slate-900 dark:text-slate-100">
      {/* Mobile Sidebar Overlay */}
      {isMobileOpen && (
        <div 
          className="fixed inset-0 z-[60] bg-slate-900/40 backdrop-blur-sm md:hidden animate-in fade-in duration-300"
          onClick={() => setIsMobileOpen(false)}
        />
      )}

      {/* Sidebar */}
      <aside
        className={cn(
          "fixed inset-y-0 left-0 z-[70] w-72 bg-brand-blue-dark text-slate-300 transition-all duration-300 ease-in-out md:static md:translate-x-0 border-r border-slate-800 shadow-2xl md:shadow-none flex flex-col",
          isMobileOpen ? "translate-x-0" : "-translate-x-full"
        )}
      >
        <div className="flex h-20 items-center justify-between px-8 border-b border-slate-800 bg-slate-900/20 shrink-0">
          <Link href="/admin" className="flex items-center gap-3">
            <div className="h-10 w-10 rounded-xl bg-brand-green/10 flex items-center justify-center overflow-hidden">
              {settings.logo ? (
                <img src={settings.logo} alt={settings.businessName} className="h-full w-full object-contain" />
              ) : (
                <ShieldCheck className="h-6 w-6 text-brand-green" />
              )}
            </div>
            <span className="font-heading text-xl font-bold text-white tracking-tight">
              {settings.shortName || "EFZ"} <span className="text-brand-green">Hub</span>
            </span>
          </Link>
          <button
            onClick={() => setIsMobileOpen(false)}
            className="p-1.5 text-slate-400 hover:text-white rounded-lg md:hidden hover:bg-slate-850 transition-colors"
            aria-label="Close sidebar"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="flex-1 px-4 py-8 flex flex-col overflow-y-auto custom-scrollbar">
          {/* Main Navigation */}
          <div className="space-y-1">
            <p className="px-3 text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.2em] mb-3">Main Navigation</p>
            {SIDEBAR_LINKS.map((link) => {
              // Determine allowed state per-link; allow scoped or action permissions for specific modules
              let allowed = true;
              if (link.href === '/admin/customers') {
                allowed = hasAnyPermission(['view_customers' as Permission, 'view_own_customers_only' as Permission]);
              } else if (link.href === '/admin/orders') {
                allowed = hasAnyPermission(['view_orders' as Permission, 'create_orders' as Permission]);
              } else if (link.href === '/admin/commissions') {
                // Officers' own commission ledger; management uses the payout tools instead.
                allowed = perms.isMarketingOfficer && hasPermission('view_commissions' as Permission);
              } else if (link.permission) {
                allowed = hasPermission(link.permission);
              }
              if (!allowed) return null;

              const Icon = link.icon;
              const isActive = pathname === link.href;
              
              return (
                <Link
                  key={link.name}
                  href={link.href}
                  className={cn(
                    "flex items-center gap-3 px-3 py-2.5 rounded-xl text-xs font-bold transition-all duration-200 group",
                    isActive 
                      ? "bg-brand-blue text-white shadow-lg shadow-brand-blue/20" 
                      : "text-slate-500 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800/50 hover:text-slate-900 dark:hover:text-slate-200"
                  )}
                  onClick={() => setIsMobileOpen(false)}
                >
                  <div className={cn(
                    "p-1.5 rounded-lg transition-colors",
                    isActive ? "bg-white/20" : "bg-slate-100 dark:bg-slate-800 group-hover:bg-white dark:group-hover:bg-slate-700"
                  )}>
                    <Icon className="h-4 w-4" />
                  </div>
                  {link.name}
                  {isActive && <div className="ml-auto w-1.5 h-1.5 rounded-full bg-white animate-pulse" />}
                </Link>
              );
            })}
          </div>

          {/* System & Logs */}
          <div className="pt-8 space-y-1">
            <p className="px-3 text-[10px] font-bold text-slate-400 dark:text-slate-500 uppercase tracking-[0.2em] mb-3">System & Security</p>
            {SYSTEM_LINKS.map((link) => {
              if (link.permission && !hasPermission(link.permission)) return null;
              const Icon = link.icon;
              const isActive = pathname === link.href;
              
              const content = (
                <div className={cn(
                  "flex items-center gap-3 px-3 py-2.5 rounded-xl text-xs font-bold transition-all duration-200 group cursor-pointer",
                  isActive 
                    ? "bg-slate-900 dark:bg-slate-100 text-white dark:text-slate-900 shadow-lg" 
                    : "text-slate-500 dark:text-slate-400 hover:bg-slate-50 dark:hover:bg-slate-800/50 hover:text-slate-900 dark:hover:text-slate-200"
                )}>
                  <div className={cn(
                    "p-1.5 rounded-lg transition-colors",
                    isActive ? "bg-white/10 dark:bg-slate-900/10" : "bg-slate-100 dark:bg-slate-800 group-hover:bg-white dark:group-hover:bg-slate-700"
                  )}>
                    <Icon className="h-4 w-4" />
                  </div>
                  {link.name}
                </div>
              );

              return (
                <Link key={link.name} href={link.href} onClick={() => setIsMobileOpen(false)}>
                  {content}
                </Link>
              );
            })}
          </div>

          <div className="mt-auto pt-10 space-y-6">
            <div className="bg-slate-800/40 rounded-2xl p-5 border border-slate-700/50">
              <div className="flex items-center gap-3 mb-3">
                <div className="h-10 w-10 rounded-xl bg-brand-blue/20 border border-brand-blue/30 overflow-hidden flex items-center justify-center">
                  {profile.avatar ? (
                    <img src={profile.avatar} alt={profile.name} className="h-full w-full object-cover" />
                  ) : (
                    <User className="h-5 w-5 text-brand-blue" />
                  )}
                </div>
                <div className="min-w-0">
                  <p className="text-xs font-bold text-white truncate">{profile.name}</p>
                  <p className="text-[10px] text-slate-500 truncate">{profile.role}</p>
                </div>
              </div>
              <Link href="/" target="_blank" className="flex items-center justify-center gap-2 w-full py-2 bg-slate-700 hover:bg-slate-600 text-[11px] font-bold text-slate-200 rounded-lg transition-colors group">
                Visit Website <ExternalLink className="h-3 w-3 group-hover:translate-x-0.5 group-hover:-translate-y-0.5 transition-transform" />
              </Link>
            </div>

            <div className="pt-4 border-t border-slate-800">
              <button
                onClick={handleLogout}
                className="flex items-center gap-3 w-full rounded-xl px-4 py-3 text-sm font-bold text-slate-400 transition-all hover:bg-red-500/10 hover:text-red-400 group"
              >
                <LogOut className="h-5 w-5 transition-transform group-hover:-translate-x-1" />
                Logout System
              </button>
            </div>
          </div>
        </div>
      </aside>

      {/* Main Content Area */}
      {/* The whole column scrolls, so the header scrolls away with the page instead of staying on top of it. */}
      <div className="flex-1 flex flex-col min-w-0 relative h-full overflow-y-auto custom-scrollbar">
        {/* Dedicated Admin Top Header */}
        <header className="relative z-50 flex h-20 items-center justify-between border-b border-slate-200 dark:border-slate-800 bg-white/80 dark:bg-slate-900/80 backdrop-blur-md px-6 md:px-10 shrink-0 transition-colors">
          <div className="flex items-center gap-4 flex-1">
            <button
              onClick={() => setIsMobileOpen(true)}
              className="p-2 text-slate-600 hover:bg-slate-100 rounded-lg md:hidden transition-colors"
            >
              <Menu className="h-6 w-6" />
            </button>
            
            <div className="hidden md:flex relative max-w-md w-full" ref={searchRef}>
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
              <input 
                type="text" 
                placeholder="Search products, orders..." 
                className="w-full h-11 pl-10 pr-4 bg-slate-50 dark:bg-slate-800 border-none rounded-xl text-sm focus:ring-2 focus:ring-brand-blue/20 transition-all dark:text-white dark:placeholder:text-slate-500"
                value={searchQuery}
                onChange={(e) => handleSearch(e.target.value)}
                onFocus={() => searchQuery.length >= 2 && setIsSearchOpen(true)}
              />

              {/* Search Results Dropdown */}
              {isSearchOpen && (
                <div className="absolute top-full left-0 mt-2 w-full bg-white dark:bg-slate-900 rounded-2xl shadow-2xl border border-slate-100 dark:border-slate-800 p-2 overflow-hidden animate-in fade-in slide-in-from-top-2">
                  <div className="max-h-[60vh] overflow-y-auto p-2 space-y-4">
                    {searchResults.products.length > 0 && (
                      <div>
                        <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest px-2 mb-2">Products</p>
                        <div className="space-y-1">
                          {searchResults.products.map(p => (
                            <Link key={p.id} href="/admin/products" onClick={() => setIsSearchOpen(false)} className="flex items-center gap-3 p-2 hover:bg-slate-50 rounded-lg transition-colors">
                              <div className="h-8 w-8 rounded bg-slate-100 overflow-hidden flex-shrink-0">
                                <img src={p.imageUrl} alt="" className="h-full w-full object-cover" />
                              </div>
                              <div className="min-w-0">
                                <p className="text-xs font-bold text-slate-900 truncate">{p.name}</p>
                                <p className="text-[10px] text-slate-500">{p.category}</p>
                              </div>
                            </Link>
                          ))}
                        </div>
                      </div>
                    )}
                    {searchResults.orders.length > 0 && (
                      <div>
                        <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest px-2 mb-2">Orders</p>
                        <div className="space-y-1">
                          {searchResults.orders.map(o => (
                            <Link key={o.id} href="/admin/orders" onClick={() => setIsSearchOpen(false)} className="flex items-center gap-3 p-2 hover:bg-slate-50 rounded-lg transition-colors">
                              <div className="h-8 w-8 rounded bg-brand-blue/10 flex items-center justify-center flex-shrink-0 text-brand-blue">
                                <ShoppingBag className="h-4 w-4" />
                              </div>
                              <div className="min-w-0">
                                <p className="text-xs font-bold text-slate-900 truncate">{o.customer}</p>
                                <p className="text-[10px] text-slate-500">{o.id} • {o.status}</p>
                              </div>
                            </Link>
                          ))}
                        </div>
                      </div>
                    )}
                    {searchResults.products.length === 0 && searchResults.orders.length === 0 && (
                      <div className="p-4 text-center">
                        <p className="text-sm text-slate-500">No results for &quot;{searchQuery}&quot;</p>
                      </div>
                    )}
                  </div>
                </div>
              )}
            </div>
          </div>

          <div className="flex items-center gap-3 md:gap-6">
            {(perms.viewDiagnostics || perms.manageSystem) && (
            <div className="hidden sm:block">
              <SystemStatusBadge />
            </div>
          )}

            <div className="flex items-center gap-2">
              <div className="relative" ref={notificationsRef}>
                <button 
                  onClick={() => setIsNotificationsOpen(!isNotificationsOpen)}
                  className={cn(
                    "h-10 w-10 flex items-center justify-center text-slate-500 hover:bg-slate-50 dark:hover:bg-slate-800 rounded-xl transition-colors relative",
                    isNotificationsOpen && "bg-slate-50 dark:bg-slate-800 text-brand-blue"
                  )}
                >
                  <Bell className="h-5 w-5" />
                  {unreadCount > 0 && (
                    <span className="absolute top-2.5 right-2.5 w-4 h-4 bg-red-500 text-white text-[10px] font-bold flex items-center justify-center rounded-full border-2 border-white">
                      {unreadCount}
                    </span>
                  )}
                </button>

                {/* Notifications Dropdown */}
                {isNotificationsOpen && (
                  <div className="absolute top-full right-0 mt-2 w-80 bg-white dark:bg-slate-900 rounded-2xl shadow-2xl border border-slate-100 dark:border-slate-800 overflow-hidden animate-in fade-in slide-in-from-top-2">
                    <div className="p-4 border-b border-slate-100 dark:border-slate-800 flex justify-between items-center bg-slate-50/50 dark:bg-slate-900/50">
                      <h3 className="text-sm font-bold text-slate-900">Notifications</h3>
                      <div className="flex gap-2">
                        <button onClick={markAllRead} className="text-[10px] font-bold text-brand-blue hover:underline">Mark all read</button>
                        <button onClick={clearNotifications} className="text-[10px] font-bold text-red-500 hover:underline">Clear</button>
                      </div>
                    </div>
                    <div className="max-h-80 overflow-y-auto">
                      {notifications.length > 0 ? (
                        notifications.map(n => (
                          <div key={n.id} className={cn("p-4 border-b border-slate-50 transition-colors", !n.read && "bg-blue-50/30")}>
                            <div className="flex gap-3">
                              <div className={cn(
                                "h-8 w-8 rounded-full flex items-center justify-center shrink-0",
                                n.type === 'stock' ? "bg-amber-100 text-amber-600" : "bg-blue-100 text-blue-600"
                              )}>
                                {n.type === 'stock' ? <Package className="h-4 w-4" /> : <ShoppingBag className="h-4 w-4" />}
                              </div>
                              <div className="min-w-0">
                                <p className="text-xs font-bold text-slate-900">{n.title}</p>
                                <p className="text-[11px] text-slate-600 mt-0.5 line-clamp-2">{n.message}</p>
                                <p className="text-[9px] text-slate-400 mt-1">{new Date(n.date).toLocaleTimeString()}</p>
                              </div>
                            </div>
                          </div>
                        ))
                      ) : (
                        <div className="p-8 text-center">
                          <p className="text-sm text-slate-400">No notifications</p>
                        </div>
                      )}
                    </div>
                  </div>
                )}
              </div>
              
              <button 
                onClick={() => setIsSettingsOpen(true)}
                className="h-10 w-10 flex items-center justify-center text-slate-500 hover:bg-slate-50 rounded-xl transition-colors"
              >
                <SettingsIcon className="h-5 w-5" />
              </button>
            </div>

            <div className="h-8 w-[1px] bg-slate-200 dark:bg-slate-800 hidden md:block mx-1" />

            <button 
              onClick={toggleTheme}
              className="h-10 w-10 flex items-center justify-center text-slate-500 hover:bg-slate-50 dark:hover:bg-slate-800 rounded-xl transition-colors"
              title={`Switch to ${theme === 'light' ? 'dark' : 'light'} mode`}
            >
              {theme === 'light' ? <Moon className="h-5 w-5" /> : <Sun className="h-5 w-5" />}
            </button>

            <div className="h-8 w-[1px] bg-slate-200 dark:bg-slate-800 hidden md:block mx-1" />

            <div className="relative" ref={profileRef}>
              <button 
                onClick={() => setIsProfileOpen(!isProfileOpen)}
                className="flex items-center gap-3 pl-2 group"
              >
                <div className="text-right hidden lg:block">
                  <p className="text-sm font-bold text-slate-900 leading-none group-hover:text-brand-blue transition-colors">{profile.name}</p>
                  <p className="text-[10px] font-medium text-slate-500 mt-1">{profile.role}</p>
                </div>
                <div className="h-10 w-10 rounded-xl bg-brand-blue flex items-center justify-center shadow-lg shadow-brand-blue/20 ring-2 ring-white ring-offset-2 ring-offset-slate-100 transition-transform group-hover:scale-105 overflow-hidden">
                  {profile.avatar ? (
                    <img src={profile.avatar} alt="" className="h-full w-full object-cover" />
                  ) : (
                    <User className="h-5 w-5 text-white" />
                  )}
                </div>
                <ChevronDown className={cn("h-4 w-4 text-slate-400 transition-transform", isProfileOpen && "rotate-180")} />
              </button>

              {/* Profile Dropdown */}
              {isProfileOpen && (
                <div className="absolute top-full right-0 mt-2 w-56 bg-white dark:bg-slate-900 rounded-2xl shadow-2xl border border-slate-100 dark:border-slate-800 p-2 overflow-hidden animate-in fade-in slide-in-from-top-2">
                  <div className="p-3 border-b border-slate-50 dark:border-slate-800 mb-1">
                    <p className="text-xs font-bold text-slate-900 dark:text-white">{profile.name}</p>
                    <p className="text-[10px] text-slate-500 dark:text-slate-400">{profile.email}</p>
                  </div>
                  <div className="space-y-0.5">
                    <button onClick={() => { setIsSettingsOpen(true); setIsProfileOpen(false); }} className="flex items-center gap-2 w-full p-2 text-xs text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800 rounded-lg transition-colors">
                      <User className="h-4 w-4" /> Profile Settings
                    </button>
                    <button onClick={() => { setIsSettingsOpen(true); setIsProfileOpen(false); }} className="flex items-center gap-2 w-full p-2 text-xs text-slate-600 dark:text-slate-300 hover:bg-slate-50 dark:hover:bg-slate-800 rounded-lg transition-colors">
                      <SettingsIcon className="h-4 w-4" /> Account Settings
                    </button>
                    <div className="h-[1px] bg-slate-50 dark:bg-slate-800 my-1" />
                    <button onClick={handleLogout} className="flex items-center gap-2 w-full p-2 text-xs text-red-600 hover:bg-red-50 rounded-lg transition-colors">
                      <LogOut className="h-4 w-4" /> Logout
                    </button>
                  </div>
                </div>
              )}
            </div>
          </div>
        </header>

        <main className="flex-1 p-6 md:p-10 lg:p-12">
          <div className="max-w-7xl mx-auto w-full">
            {isAccessDenied ? (
              <div className="min-h-[60vh] flex items-center justify-center">
                <div className="text-center space-y-4 max-w-md animate-in fade-in zoom-in duration-500">
                  <div className="h-20 w-20 bg-red-100 text-red-600 rounded-3xl flex items-center justify-center mx-auto shadow-xl shadow-red-100/50">
                    <Lock className="h-10 w-10" />
                  </div>
                  <div>
                    <h2 className="text-2xl font-bold text-slate-900 tracking-tight">Access Restricted</h2>
                    <p className="text-slate-500 mt-2 text-sm leading-relaxed">
                      Your account role (<span className="font-bold text-slate-700">{profile.role}</span>) does not have the required permissions to access this module.
                    </p>
                  </div>
                  <Button 
                    onClick={() => router.push("/admin")}
                    className="bg-slate-900 text-white hover:bg-slate-800 rounded-xl px-8"
                  >
                    Return to Overview
                  </Button>
                </div>
              </div>
            ) : children}
          </div>
          
          <footer className="py-10 text-center">
            <p className="text-[11px] font-medium text-slate-400 uppercase tracking-widest">
              {settings.businessName} &bull; Inventory Management &bull; &copy; {new Date().getFullYear()}
            </p>
          </footer>
        </main>
      </div>

      {/* Global Settings & Profile Modal */}
      {isSettingsOpen && (
        <div className="fixed inset-0 z-[100] bg-slate-900/60 backdrop-blur-sm flex items-center justify-center p-4">
          <div className="bg-white dark:bg-slate-900 rounded-3xl shadow-2xl w-full max-w-2xl max-h-[90vh] overflow-y-auto animate-in zoom-in duration-200 border dark:border-slate-800">
            <div className="p-6 border-b dark:border-slate-800 flex justify-between items-center sticky top-0 bg-white dark:bg-slate-900 z-10">
              <h2 className="text-xl font-bold text-slate-900 dark:text-white flex items-center gap-2">
                <SettingsIcon className="h-5 w-5 text-brand-blue" />
                Settings & Profile
              </h2>
              <button onClick={() => setIsSettingsOpen(false)} className="p-2 hover:bg-slate-100 rounded-full transition-colors">
                <X className="h-5 w-5 text-slate-400" />
              </button>
            </div>
            
            <div className="p-6 space-y-8">
              {/* Profile Section */}
              <section>
                <h3 className="text-sm font-bold text-slate-400 uppercase tracking-widest mb-4 flex items-center gap-2">
                  <User className="h-4 w-4" /> Profile Identity
                </h3>
                <div className="grid grid-cols-1 md:grid-cols-3 gap-6 items-start">
                  <div className="flex flex-col items-center gap-3">
                    <div 
                      className="h-24 w-24 rounded-2xl bg-slate-100 border-2 border-dashed border-slate-200 flex items-center justify-center relative group overflow-hidden cursor-pointer"
                      onClick={() => avatarInputRef.current?.click()}
                    >
                      {profile.avatar ? (
                        <img src={profile.avatar} className="h-full w-full object-cover" alt="" />
                      ) : (
                        <Plus className="h-6 w-6 text-slate-300" />
                      )}
                      <div className="absolute inset-0 bg-black/40 opacity-0 group-hover:opacity-100 flex items-center justify-center transition-opacity">
                        <Upload className="h-6 w-6 text-white" />
                      </div>
                      <input 
                        type="file" 
                        ref={avatarInputRef}
                        className="hidden" 
                        accept="image/*"
                        onChange={(e) => {
                          const file = e.target.files?.[0];
                          if (file) {
                            if (file.size > 1024 * 1024) {
                              showToast('error', 'Avatar image must be under 1MB');
                              return;
                            }
                            const reader = new FileReader();
                            reader.onloadend = () => setProfile({...profile, avatar: reader.result as string});
                            reader.readAsDataURL(file);
                          }
                        }}
                      />
                    </div>
                    <p className="text-[10px] text-slate-400 text-center">Click to upload avatar<br/>(Max 1MB)</p>
                  </div>
                  <div className="md:col-span-2 space-y-4">
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                      <div className="space-y-1">
                        <label className="text-xs font-bold text-slate-600">Display Name</label>
                        <Input value={profile.name} onChange={e => setProfile({...profile, name: e.target.value})} />
                      </div>
                      <div className="space-y-1">
                        <label className="text-xs font-bold text-slate-600">Email Address</label>
                        <Input value={profile.email} onChange={e => setProfile({...profile, email: e.target.value})} />
                      </div>
                    </div>
                    <Button onClick={saveProfile} className="w-full bg-slate-900 text-white hover:bg-slate-800 transition-all">Save Profile Changes</Button>
                  </div>
                </div>
              </section>

              {/* Company-wide settings: Super Admin only (RLS settings_update = is_super_admin()). Others see their own profile. */}
              {perms.isSuperAdmin ? (
              <>
              {/* Branding Section */}
              <section className="pt-8 border-t border-slate-100">
                <h3 className="text-sm font-bold text-slate-400 uppercase tracking-widest mb-4 flex items-center gap-2">
                  <ImageIcon className="h-4 w-4" /> Branding & Visuals
                </h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
                  <div className="space-y-4">
                    <label className="text-xs font-bold text-slate-600 block">Business Logo</label>
                    <div 
                      className="h-32 w-full rounded-2xl bg-slate-50 border-2 border-dashed border-slate-200 flex items-center justify-center relative group overflow-hidden cursor-pointer hover:border-brand-blue/30 transition-all"
                      onClick={() => {
                        const input = document.createElement('input');
                        input.type = 'file';
                        input.accept = 'image/*';
                        input.onchange = (e) => {
                          const file = (e.target as HTMLInputElement).files?.[0];
                          if (file) {
                            const reader = new FileReader();
                            reader.onloadend = () => setSettings({...settings, logo: reader.result as string});
                            reader.readAsDataURL(file);
                          }
                        };
                        input.click();
                      }}
                    >
                      {settings.logo ? (
                        <img src={settings.logo} className="h-full w-full object-contain p-4" alt="" />
                      ) : (
                        <div className="flex flex-col items-center gap-2 text-slate-400">
                          <Upload className="h-6 w-6" />
                          <span className="text-[10px] font-bold">Upload Main Logo</span>
                        </div>
                      )}
                      <div className="absolute inset-0 bg-black/20 opacity-0 group-hover:opacity-100 flex items-center justify-center transition-opacity">
                        <Plus className="h-6 w-6 text-white" />
                      </div>
                    </div>
                  </div>

                  <div className="space-y-4">
                    <label className="text-xs font-bold text-slate-600 block">Favicon / Icon</label>
                    <div 
                      className="h-32 w-full rounded-2xl bg-slate-50 border-2 border-dashed border-slate-200 flex items-center justify-center relative group overflow-hidden cursor-pointer hover:border-brand-blue/30 transition-all"
                      onClick={() => {
                        const input = document.createElement('input');
                        input.type = 'file';
                        input.accept = 'image/*';
                        input.onchange = (e) => {
                          const file = (e.target as HTMLInputElement).files?.[0];
                          if (file) {
                            const reader = new FileReader();
                            reader.onloadend = () => setSettings({...settings, favicon: reader.result as string});
                            reader.readAsDataURL(file);
                          }
                        };
                        input.click();
                      }}
                    >
                      {settings.favicon ? (
                        <img src={settings.favicon} className="h-12 w-12 object-contain" alt="" />
                      ) : (
                        <div className="flex flex-col items-center gap-2 text-slate-400">
                          <Plus className="h-6 w-6" />
                          <span className="text-[10px] font-bold">Upload Favicon</span>
                        </div>
                      )}
                    </div>
                  </div>
                </div>

                <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mt-6">
                  <div className="space-y-2">
                    <label className="text-xs font-bold text-slate-600">Primary Brand Color</label>
                    <div className="flex gap-2">
                      <input 
                        type="color" 
                        value={settings.primaryColor} 
                        onChange={e => setSettings({...settings, primaryColor: e.target.value})}
                        className="h-10 w-10 rounded border-none cursor-pointer"
                      />
                      <Input value={settings.primaryColor} onChange={e => setSettings({...settings, primaryColor: e.target.value})} className="font-mono text-xs" />
                    </div>
                  </div>
                  <div className="space-y-2">
                    <label className="text-xs font-bold text-slate-600">Secondary Accent Color</label>
                    <div className="flex gap-2">
                      <input 
                        type="color" 
                        value={settings.secondaryColor} 
                        onChange={e => setSettings({...settings, secondaryColor: e.target.value})}
                        className="h-10 w-10 rounded border-none cursor-pointer"
                      />
                      <Input value={settings.secondaryColor} onChange={e => setSettings({...settings, secondaryColor: e.target.value})} className="font-mono text-xs" />
                    </div>
                  </div>
                </div>
              </section>

              {/* Business Settings */}
              <section className="pt-8 border-t border-slate-100">
                <h3 className="text-sm font-bold text-slate-400 uppercase tracking-widest mb-4 flex items-center gap-2">
                  <Globe className="h-4 w-4" /> Global Business Settings
                </h3>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
                  <div className="space-y-1">
                    <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5"><ShieldCheck className="h-3 w-3" /> Full Business Name</label>
                    <Input value={settings.businessName} onChange={e => setSettings({...settings, businessName: e.target.value})} />
                  </div>
                  <div className="space-y-1">
                    <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5"><Globe className="h-3 w-3" /> Short Brand Name (Sidebar)</label>
                    <Input value={settings.shortName} onChange={e => setSettings({...settings, shortName: e.target.value})} />
                  </div>
                  <div className="space-y-1">
                    <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5"><Smartphone className="h-3 w-3" /> WhatsApp Order Phone</label>
                    <Input value={settings.whatsappNumber} onChange={e => setSettings({...settings, whatsappNumber: e.target.value})} />
                  </div>
                  <div className="space-y-1">
                    <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5"><Mail className="h-3 w-3" /> Contact Email</label>
                    <Input value={settings.contactEmail} onChange={e => setSettings({...settings, contactEmail: e.target.value})} />
                  </div>
                  <div className="space-y-1">
                    <label className="text-xs font-bold text-slate-600 flex items-center gap-1.5"><Info className="h-3 w-3" /> Default Stock Threshold</label>
                    <Input type="number" value={settings.defaultLowStockThreshold} onChange={e => setSettings({...settings, defaultLowStockThreshold: parseInt(e.target.value)})} />
                  </div>
                </div>
                <div className="mt-6 flex gap-3">
                  <Button onClick={saveSettings} className="flex-1 bg-brand-blue text-white">Save All System Settings</Button>
                  <Button variant="outline" onClick={() => setIsSettingsOpen(false)} className="flex-1">Discard Changes</Button>
                </div>
              </section>
              </>
              ) : (
                <section className="pt-8 border-t border-slate-100" data-testid="company-settings-locked">
                  <p className="flex items-center gap-2 text-xs text-slate-500">
                    <ShieldCheck className="h-3.5 w-3.5" /> Company settings (business name, branding, contact details, theme) are managed by the Super Admin.
                  </p>
                </section>
              )}

              {/* Data Backup & Recovery Section - backups hold every core table: manage_system only (RLS backups_all). */}
              {perms.manageSystem && (
              <section className="pt-8 border-t border-slate-100">
                <h3 className="text-sm font-bold text-slate-400 uppercase tracking-widest mb-4 flex items-center gap-2">
                  <Database className="h-4 w-4" /> Data Backup & Recovery
                </h3>
                
                <div className="grid grid-cols-2 md:grid-cols-3 gap-4 mb-6">
                  {Object.entries(dataCounts).map(([key, count]) => (
                    <div key={key} className="bg-slate-50 rounded-2xl p-4 border border-slate-100">
                      <p className="text-[10px] font-bold text-slate-400 uppercase tracking-wider">{key}</p>
                      <p className="text-xl font-bold text-slate-900">{count}</p>
                    </div>
                  ))}
                </div>

                <div className="space-y-4">
                  <div className="flex flex-col md:flex-row gap-4">
                    <Button
                      onClick={handleExportBackup}
                      disabled={isBackingUp}
                      className="flex-1 bg-brand-blue text-white"
                    >
                      <Download className="h-4 w-4 mr-2" /> {isBackingUp ? 'Snapshotting…' : 'Export Backup'}
                    </Button>

                    <Button variant="outline" onClick={handleRefreshBackups} disabled={isBackingUp} className="flex-1">
                      <History className="h-4 w-4 mr-2" /> Refresh Snapshot List
                    </Button>
                  </div>

                  <div className="bg-amber-50 border border-amber-100 rounded-2xl p-4">
                    <div className="flex items-center gap-2 text-amber-800 mb-2">
                      <Clock className="h-4 w-4" />
                      <span className="text-xs font-bold uppercase tracking-wider">Snapshot Status</span>
                    </div>
                    <p className="text-xs text-amber-700">
                      {lastBackupAt
                        ? `Last snapshot: ${new Date(lastBackupAt).toLocaleString()}`
                        : "No snapshot recorded yet."}
                    </p>
                  </div>

                  {/* Restore and factory reset used to rewrite localStorage in the
                      browser. Against a real database those are destructive
                      operations that belong in a reviewed, server-side script -
                      not behind a button in the admin chrome. */}
                  <div className="pt-4 border-t border-slate-100">
                    <p className="text-xs font-bold text-slate-400 uppercase tracking-widest mb-3">Restore</p>
                    <div className="bg-slate-50 border border-slate-100 rounded-2xl p-4">
                      <p className="text-[10px] text-slate-600 leading-relaxed font-medium">
                        Restoring a snapshot now runs against PostgreSQL, so it is handled outside the app:
                        generate the SQL with <code className="font-mono text-slate-800">node scripts/generate-supabase-import.mjs</code>,
                        review it, then run it in the Supabase SQL Editor. Supabase&apos;s own
                        Point-in-Time Recovery covers full database rollbacks.
                      </p>
                    </div>
                  </div>
                </div>
              </section>
              )}
            </div>
          </div>
        </div>
      )}
      {/* Toast Notification */}
      {toast && (
        <div className={cn(
          "fixed bottom-8 right-8 z-[200] flex items-center gap-3 px-6 py-4 rounded-2xl shadow-2xl border animate-in slide-in-from-right-10 duration-300",
          toast.type === 'success' ? "bg-white border-green-100 text-slate-900" : "bg-red-50 border-red-100 text-red-900"
        )}>
          <div className={cn(
            "h-8 w-8 rounded-full flex items-center justify-center shrink-0",
            toast.type === 'success' ? "bg-green-100 text-green-600" : "bg-red-100 text-red-600"
          )}>
            {toast.type === 'success' ? <ShieldCheck className="h-4 w-4" /> : <X className="h-4 w-4" />}
          </div>
          <p className="text-sm font-bold pr-2">{toast.message}</p>
        </div>
      )}
    </div>
  );
}



