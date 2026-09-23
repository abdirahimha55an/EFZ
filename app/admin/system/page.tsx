"use client";

import { useCallback, useEffect, useState } from "react";
import {
  Download, ShieldCheck,
  Trash2, RefreshCw, AlertTriangle,
  ShieldAlert, HardDrive, Activity, Loader2
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { AdminProfile } from "@/lib/types";
import type { OperationalMetrics } from "@/lib/supabase/database.types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export default function SystemManagementPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [profile, setProfile] = useState<AdminProfile | null>(null);
  const [metrics, setMetrics] = useState<OperationalMetrics | null>(null);
  const [lastExport, setLastExport] = useState<string | null>(null);
  const [isBusy, setIsBusy] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);

  const loadAll = useCallback(async () => {
    const db = getDb();
    const nextProfile = await db.auth.getProfile();
    setProfile(nextProfile);
    if (!nextProfile) return;

    // operational_metrics() needs view_diagnostics; manage_system implies it in
    // practice, but a Super Admin short-circuits either way.
    if (derivePermissions(nextProfile).viewDiagnostics) {
      setMetrics(await db.issues.metrics());
    }

    const snapshots = await db.backups.list();
    setLastExport(snapshots[0]?.created_at ?? null);
  }, []);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        await loadAll();
        if (!cancelled) setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsMounted(true);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [loadAll]);

  const canManageSystem = derivePermissions(profile).manageSystem;

  if (!isMounted) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading system status…</p>
      </div>
    );
  }

  /**
   * Runs the two automatic repairs the database exposes: order totals and
   * profile commission totals, each recomputed from its source rows.
   *
   * The old "Repair Storage" re-indexed duplicate user IDs and fixed broken
   * object references. Neither is possible now - a primary key refuses the
   * first and a foreign key the second - so that button had nothing left to do.
   */
  const handleRepair = async () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to perform system maintenance.');
      return;
    }
    if (!confirm("Recompute order totals and commission totals from their source rows?\n\nThis rewrites stored values that have drifted. It does not change any order lines, payments or commission rows.")) return;

    try {
      setIsBusy(true);
      const db = getDb();
      const [orderRepair, commissionRepair] = await Promise.all([
        db.issues.repair('orders-total-drift'),
        db.issues.repair('commission-totals-drift'),
      ]);
      await loadAll();
      alert(
        `Repair complete.\n\n` +
        `Order totals recomputed: ${orderRepair.recordsFixed}\n` +
        `Commission totals recomputed: ${commissionRepair.recordsFixed}`
      );
    } catch (error) {
      alert('Repair failed: ' + describeDbError(error));
    } finally {
      setIsBusy(false);
    }
  };

  /** Runs the nine-check scan in the database and reports what it found. */
  const handleIntegrityCheck = async () => {
    try {
      setIsBusy(true);
      const db = getDb();
      await db.issues.scan();
      const open = await db.issues.list();
      await loadAll();

      if (open.length === 0) {
        alert('Validation complete. No open findings.');
        return;
      }

      const lines = open
        .slice(0, 12)
        .map(issue => `- [${issue.severity}] ${issue.title} (${issue.affectedCount})`)
        .join('\n');

      alert(
        `Validation complete. ${open.length} open finding(s):\n\n${lines}` +
        (open.length > 12 ? `\n... and ${open.length - 12} more.` : '') +
        `\n\nFull detail is in the Operation Center.`
      );
    } catch (error) {
      alert('Validation failed: ' + describeDbError(error));
    } finally {
      setIsBusy(false);
    }
  };

  /** Writes a `backups` row and hands the same payload over as a download. */
  const handleExport = async () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to export backups.');
      return;
    }

    let url: string | null = null;
    const link = document.createElement('a');

    try {
      setIsBusy(true);
      const db = getDb();
      const snapshot = await db.backups.create(
        `System export by ${profile?.name ?? 'staff'} on ${new Date().toISOString().slice(0, 10)}`
      );

      await db.logs.write({
        category: 'SYSTEM',
        severity: 'INFO',
        message: 'Full system backup exported',
        targetId: snapshot.id,
      });

      const blob = new Blob([JSON.stringify(snapshot, null, 2)], { type: 'application/json' });
      url = URL.createObjectURL(blob);
      link.href = url;
      link.download = `efz_full_backup_${new Date().toISOString().split('T')[0]}.json`;
      document.body.appendChild(link);
      link.click();

      await loadAll();
      alert('Snapshot saved and download started.');
    } catch (error) {
      alert('Failed to export backup: ' + describeDbError(error));
    } finally {
      if (link.parentNode) link.parentNode.removeChild(link);
      if (url) URL.revokeObjectURL(url);
      setIsBusy(false);
    }
  };

  const recordRows: Array<[string, number]> = metrics
    ? Object.entries(metrics.records).map(([key, value]) => [key, Number(value ?? 0)])
    : [];
  const totalRecords = recordRows.reduce((sum, [, count]) => sum + count, 0);

  return (
    <div className="space-y-8 animate-in fade-in duration-500 max-w-6xl mx-auto">
      <div>
        <h1 className="text-3xl font-black text-slate-900 dark:text-white tracking-tight">System Management</h1>
        <p className="text-slate-500 dark:text-slate-400 mt-1 font-medium">Core infrastructure control and disaster recovery tools.</p>
        {loadError && (
          <p className="mt-2 text-xs font-medium text-red-600">{loadError}</p>
        )}
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Left Column: Status & Storage */}
        <div className="lg:col-span-1 space-y-8">
          <Card className="rounded-[2rem] border-slate-100 shadow-sm overflow-hidden">
            <CardHeader className="bg-slate-50/50">
              <CardTitle className="text-sm font-bold flex items-center gap-2">
                <HardDrive className="h-4 w-4 text-slate-400" /> Stored Records
              </CardTitle>
            </CardHeader>
            <CardContent className="pt-6">
              {/* Was a localStorage quota gauge. There is no 5MB ceiling to
                  watch any more, so this reports what is actually stored. */}
              <div className="text-center space-y-2">
                <div className="inline-flex items-center justify-center h-24 w-24 rounded-full border-4 border-slate-100 border-t-brand-blue">
                   <span className="text-xl font-black">{totalRecords.toLocaleString()}</span>
                </div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Rows in PostgreSQL</p>
              </div>
              <div className="mt-8 space-y-3">
                {recordRows.map(([label, count]) => (
                   <div key={label} className="flex items-center justify-between p-3 bg-slate-50 rounded-xl border border-slate-100">
                     <span className="text-[10px] font-mono font-bold text-slate-500">{label}</span>
                     <span className="text-[10px] font-black text-slate-700">{count.toLocaleString()}</span>
                   </div>
                ))}
                {recordRows.length === 0 && (
                  <p className="text-center text-[10px] font-medium text-slate-400">
                    Row counts need the view_diagnostics permission.
                  </p>
                )}
              </div>
            </CardContent>
          </Card>

          <Card className="rounded-[2rem] border-slate-100 shadow-sm overflow-hidden bg-brand-blue-dark text-white">
            <CardContent className="p-6 space-y-6">
              <div className="flex items-center gap-3">
                <div className="h-10 w-10 rounded-xl bg-white/10 flex items-center justify-center">
                  <Activity className="h-5 w-5" />
                </div>
                <div>
                  <p className="text-[10px] font-bold opacity-60 uppercase tracking-widest">Last Backup</p>
                  <p className="text-sm font-bold">{lastExport ? new Date(lastExport).toLocaleString() : 'Never'}</p>
                </div>
              </div>
              <Button onClick={handleExport} className="w-full bg-white text-slate-900 hover:bg-slate-100 rounded-xl font-bold h-12 shadow-xl">
                 <Download className="h-4 w-4 mr-2" /> Export System Backup
              </Button>
            </CardContent>
          </Card>
        </div>

        {/* Right Column: Management Actions */}
        <div className="lg:col-span-2 space-y-8">
          <section className="space-y-4">
             <h3 className="text-xs font-bold text-slate-400 uppercase tracking-widest px-2">Maintenance & Recovery</h3>
             <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
                <ActionButton
                  icon={RefreshCw}
                  title="Recompute Stored Totals"
                  description="Rebuild order totals and commission totals from their source rows. Use when diagnostics reports drift."
                  onClick={handleRepair}
                  disabled={!canManageSystem || isBusy}
                />
                <ActionButton
                  icon={ShieldCheck}
                  title="Validate Integrity"
                  description="Run the nine-check scan in the database and report every open finding."
                  onClick={handleIntegrityCheck}
                  disabled={isBusy}
                />
             </div>
          </section>

          {/* Restore, log deletion and factory reset used to rewrite or wipe
              localStorage. Against PostgreSQL each is either impossible by
              design or too destructive to sit behind a button, so the page
              explains where the capability actually lives. */}
          <section className="space-y-4">
             <h3 className="text-xs font-bold text-slate-400 uppercase tracking-widest px-2">Operations that moved</h3>
             <Card className="rounded-[2rem] border-slate-100 overflow-hidden">
                <CardContent className="p-6 space-y-5">
                   <MovedOperation
                     icon={Trash2}
                     title="Clear Audit Logs"
                     body="Not possible, by design. `system_logs` has an insert policy and no delete policy at all — nobody, including a Super Admin, can erase an entry. An audit trail anyone can clear is not an audit trail."
                   />
                   <MovedOperation
                     icon={AlertTriangle}
                     title="Restore from Backup"
                     body="Overwriting a live database belongs in a reviewed script, not a file picker. Generate the SQL with `node scripts/generate-supabase-import.mjs`, read it, then run it in the Supabase SQL Editor."
                   />
                   <MovedOperation
                     icon={AlertTriangle}
                     title="Factory Data Reset"
                     body="Removed. It called localStorage.clear(), which now clears nothing. To roll the whole database back, use Supabase's Point-in-Time Recovery."
                   />
                </CardContent>
             </Card>
          </section>

          {!canManageSystem && (
             <div className="p-6 rounded-3xl bg-amber-50 border border-amber-100 flex items-center gap-4">
                <ShieldAlert className="h-6 w-6 text-amber-600" />
                <p className="text-xs font-bold text-amber-700">Some management actions are restricted to users with system management permission.</p>
             </div>
          )}
        </div>
      </div>
    </div>
  );
}

/** A capability that did not survive the move, and where it went instead. */
function MovedOperation({ icon: Icon, title, body }: { icon: LucideIcon; title: string; body: string }) {
  return (
    <div className="flex items-start gap-4">
      <div className="h-10 w-10 shrink-0 rounded-xl bg-slate-100 text-slate-400 flex items-center justify-center">
        <Icon className="h-5 w-5" />
      </div>
      <div className="space-y-1">
        <h4 className="text-sm font-bold text-slate-900 flex items-center gap-2">
          {title}
          <span className="rounded-full bg-slate-100 px-2 py-0.5 text-[9px] font-black uppercase tracking-widest text-slate-500">
            Moved
          </span>
        </h4>
        <p className="text-[11px] leading-relaxed font-medium text-slate-500">{body}</p>
      </div>
    </div>
  );
}

function ActionButton({ icon: Icon, title, description, onClick, danger, disabled }: {
  icon: LucideIcon;
  title: string;
  description: string;
  onClick: () => void;
  danger?: boolean;
  disabled?: boolean;
}) {
  return (
    <button 
      onClick={onClick}
      disabled={disabled}
      className={cn(
        "flex items-start gap-4 p-6 rounded-[2rem] border text-left transition-all group relative overflow-hidden",
        disabled ? "opacity-50 cursor-not-allowed bg-slate-50 border-slate-100" :
        danger ? "bg-white border-red-50 hover:border-red-100 hover:shadow-xl hover:shadow-red-50" : 
        "bg-white border-slate-100 hover:border-brand-blue/20 hover:shadow-xl hover:shadow-slate-100"
      )}
    >
      <div className={cn(
        "h-12 w-12 rounded-2xl flex items-center justify-center shrink-0 transition-transform group-hover:scale-110",
        danger ? "bg-red-50 text-red-600" : "bg-slate-50 text-slate-400 group-hover:bg-brand-blue/10 group-hover:text-brand-blue"
      )}>
        <Icon className="h-6 w-6" />
      </div>
      <div className="space-y-1">
        <h4 className={cn("text-sm font-bold tracking-tight", danger ? "text-red-600" : "text-slate-900")}>{title}</h4>
        <p className="text-[11px] text-slate-500 leading-relaxed font-medium">{description}</p>
      </div>
    </button>
  );
}
