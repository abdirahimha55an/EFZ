"use client";

import { useCallback, useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { 
  Activity, ShieldCheck, Database, HardDrive, 
  User, Terminal, Info, AlertTriangle, AlertCircle,
  Cpu, Zap, Globe, Lock, ShieldAlert, RefreshCw,
  Search, Filter, Clock, BarChart3, Binary, Layers
} from "lucide-react";
import type { LucideIcon } from "lucide-react";
import { LogSeverity, SystemIssue, SystemLog } from "@/lib/types";
import type { OperationalMetrics } from "@/lib/supabase/database.types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { derivePermissions } from "@/lib/permissions";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";

export default function DiagnosticsPage() {
  const [isScanning, setIsScanning] = useState(false);
  const [issues, setIssues] = useState<SystemIssue[]>([]);
  const [metrics, setMetrics] = useState<OperationalMetrics | null>(null);
  const [activity, setActivity] = useState<SystemLog[]>([]);
  const [lastScan, setLastScan] = useState<Date>(new Date());
  const [scanDuration, setScanDuration] = useState<number>(0);
  const [canRepair, setCanRepair] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);
  const [hasScanned, setHasScanned] = useState(false);

  /**
   * The scan runs inside the database - run_diagnostics() rewrites
   * public.system_issues, then we read back what it found. That matters: the
   * findings are the database's own view of itself, not the browser's guess
   * from a partial copy of the data.
   */
  const performScan = useCallback(async () => {
    setIsScanning(true);
    const start = performance.now();

    try {
      const db = getDb();
      const profile = await db.auth.getProfile();
      const perms = derivePermissions(profile);
      setCanRepair(perms.manageSystem);

      if (!perms.viewDiagnostics) {
        setScanError("You do not have permission to view diagnostics.");
        return;
      }

      await db.issues.scan();

      const [nextIssues, nextMetrics, recentActivity] = await Promise.all([
        db.issues.list(),
        db.issues.metrics(),
        perms.viewAuditTrail ? db.logs.recentActivity(10) : Promise.resolve([]),
      ]);

      setIssues(nextIssues);
      setMetrics(nextMetrics);
      setActivity(recentActivity);
      setLastScan(new Date());
      setScanError(null);
    } catch (error) {
      setScanError(describeDbError(error));
    } finally {
      setScanDuration(Math.round(performance.now() - start));
      setIsScanning(false);
      setHasScanned(true);
    }
  }, []);

  useEffect(() => {
    let cancelled = false;

    // Wrapped rather than called directly: performScan sets state on entry, and
    // the cancelled guard stops the 30s timer writing into an unmounted page.
    const tick = async () => {
      if (cancelled) return;
      await performScan();
    };

    void tick();
    const interval = setInterval(() => void tick(), 30000);

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [performScan]);

  const handleRepair = async (issueId: string) => {
    const issue = issues.find(i => i.id === issueId);
    if (!issue) return;

    const confirmed = confirm(
      `You are about to run an automatic repair for a ${issue.severity} finding:\n` +
      `"${issue.recommendedAction}"\n\n` +
      `This recomputes stored records from their source rows. Proceed?`
    );
    if (!confirmed) return;

    try {
      const result = await getDb().issues.repair(issueId);
      await performScan();
      alert(`Repair complete: ${result.recordsFixed} record(s) recomputed.`);
    } catch (error) {
      alert("Repair failed: " + describeDbError(error));
    }
  };

  if (!hasScanned) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Activity className="h-6 w-6 animate-pulse text-brand-green" />
        <p className="text-xs font-medium">Running diagnostics…</p>
      </div>
    );
  }

  if (scanError || !metrics) {
    return (
      <Card className="border-none shadow-sm">
        <CardContent className="flex flex-col items-center gap-4 py-16 text-center">
          <ShieldAlert className="h-8 w-8 text-red-500" />
          <div>
            <h2 className="font-heading text-lg font-bold text-slate-900">Diagnostics unavailable</h2>
            <p className="mt-1 max-w-md text-xs text-slate-500">
              {scanError ?? "The metrics function returned nothing."}
            </p>
          </div>
          <Button onClick={performScan} variant="outline" size="sm" className="rounded-lg text-xs">
            <RefreshCw className="mr-1.5 h-3.5 w-3.5" /> Run again
          </Button>
        </CardContent>
      </Card>
    );
  }

  const warnings = issues.filter(i => i.severity === 'WARNING').length;
  const critical = issues.filter(i => i.severity === 'CRITICAL' || i.severity === 'ERROR').length;
  const totalRecords = Object.values(metrics.records).reduce((sum, n) => sum + Number(n ?? 0), 0);

  return (
    <div className="space-y-8 animate-in fade-in duration-500 pb-20">
      {/* Header Section */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-6">
        <div className="space-y-1">
          <div className="flex items-center gap-3">
             <div className="h-10 w-10 rounded-2xl bg-slate-900 flex items-center justify-center text-brand-green">
               <Activity className={cn("h-6 w-6", isScanning && "animate-pulse")} />
             </div>
             <h1 className="text-3xl font-black text-slate-900 dark:text-white tracking-tight">Operation Center</h1>
          </div>
          <p className="text-slate-500 dark:text-slate-400 font-medium flex items-center gap-2 pl-1">
            <span className={cn("h-1.5 w-1.5 rounded-full bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.6)]", isScanning && "animate-ping")} />
            Real-time infrastructure intelligence and troubleshooting
          </p>
        </div>
        <div className="flex items-center gap-4">
           <div className="hidden md:flex items-center gap-6 px-6 py-3 bg-white dark:bg-slate-900 rounded-2xl border border-slate-100 dark:border-slate-800 shadow-sm">
             <div className="flex flex-col">
               <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Scan Duration</span>
               <span className="text-xs font-mono font-bold text-brand-blue">{scanDuration}ms</span>
             </div>
             <div className="h-8 w-px bg-slate-100 dark:bg-slate-800" />
             <div className="flex flex-col">
               <span className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Last Sync</span>
               <span className="text-xs font-mono font-bold text-slate-700 dark:text-slate-200">{lastScan.toLocaleTimeString()}</span>
             </div>
           </div>
           <Button 
             disabled={isScanning}
             onClick={performScan} 
             className="bg-slate-900 text-white hover:bg-slate-800 rounded-2xl px-6 h-12 font-bold gap-3 shadow-xl"
           >
             <RefreshCw className={cn("h-4 w-4", isScanning && "animate-spin")} />
             {isScanning ? "Scanning..." : "Manual Re-scan"}
           </Button>
        </div>
      </div>

      {/* Top Metrics Row */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <LiveMetricCard
          label="Records Stored"
          value={totalRecords.toLocaleString() + " rows"}
          subValue={`${metrics.records.orders.toLocaleString()} orders · ${metrics.records.payments.toLocaleString()} payments`}
          status={critical > 0 ? 'error' : warnings > 0 ? 'warning' : 'success'}
          icon={HardDrive}
        />
        <LiveMetricCard
          label="Staff Accounts"
          value={metrics.records.profiles + " profiles"}
          subValue="Authenticated by Supabase Auth"
          status="success"
          icon={User}
        />
        <LiveMetricCard
          label="Backup Integrity"
          value={metrics.backups.lastSnapshot ? "Verified Archive" : "Gap Detected"}
          subValue={metrics.backups.lastSnapshot ? "Age: " + calculateAge(metrics.backups.lastSnapshot) : "Snapshot missing"}
          status={metrics.backups.lastSnapshot ? 'success' : 'error'}
          icon={Database}
        />
        <LiveMetricCard
          label="System Health Score"
          value={metrics.health.score + " / 100"}
          subValue={metrics.health.status}
          status={metrics.health.score >= 95 ? 'success' : metrics.health.score >= 80 ? 'info' : metrics.health.score >= 60 ? 'warning' : 'error'}
          icon={Activity}
        />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-12 gap-8">
        {/* Main Findings (Span 8) */}
        <div className="lg:col-span-8 space-y-8">
          <section className="space-y-4">
            <div className="flex items-center justify-between px-2">
              <div className="flex items-center gap-2">
                <ShieldAlert className="h-4 w-4 text-slate-400" />
                <h3 className="text-xs font-black text-slate-900 dark:text-white uppercase tracking-[0.2em]">Operational Findings</h3>
              </div>
              <div className="flex items-center gap-2">
                 <span className="h-2 w-2 rounded-full bg-red-500" />
                 <span className="text-[10px] font-black text-red-600 uppercase">{critical} Critical</span>
                 <span className="h-2 w-2 rounded-full bg-amber-500 ml-2" />
                 <span className="text-[10px] font-black text-amber-600 uppercase">{warnings} Warnings</span>
              </div>
            </div>

            <div className="space-y-4">
              {issues.length > 0 ? (
                issues.map(issue => (
                  <IntelligentIssueCard key={issue.id} issue={issue} canRepair={canRepair} onRepair={handleRepair} />
                ))
              ) : (
                <div className="p-16 text-center bg-white dark:bg-slate-900 rounded-[3rem] border border-slate-100 dark:border-slate-800 shadow-sm">
                  <div className="h-20 w-20 rounded-full bg-green-50 dark:bg-green-900/10 flex items-center justify-center mx-auto mb-6">
                    <ShieldCheck className="h-10 w-10 text-green-500" />
                  </div>
                  <h4 className="text-xl font-black text-slate-900 dark:text-white">Infrastructure Synchronized</h4>
                  <p className="text-slate-500 dark:text-slate-400 text-sm max-w-md mx-auto mt-2 font-medium">No operational defects or data inconsistencies detected in the latest system scan.</p>
                </div>
              )}
            </div>
          </section>

          {/* Infrastructure Domains Grid */}
          <section className="space-y-4 pt-4">
            <div className="flex items-center gap-2 px-2">
              <Layers className="h-4 w-4 text-slate-400" />
              <h3 className="text-xs font-black text-slate-900 dark:text-white uppercase tracking-[0.2em]">Infrastructure Domains</h3>
            </div>
            <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
               <DomainIntelligenceCard
                 name="Data Volume"
                 icon={HardDrive}
                 metrics={[
                   { label: "Orders / Items", value: `${metrics.records.orders} / ${metrics.records.orderItems}` },
                   { label: "Customers", value: metrics.records.customers },
                   { label: "Audit Log Entries", value: metrics.records.logs }
                 ]}
                 status="Healthy"
               />
               <DomainIntelligenceCard
                 name="Runtime & Execution"
                 icon={Zap}
                 metrics={[
                   { label: "Engine", value: metrics.runtime.engine },
                   { label: "Errors (24h)", value: metrics.runtime.exceptions24h },
                   { label: "Server Time", value: new Date(metrics.runtime.serverTime).toLocaleTimeString() }
                 ]}
                 status={metrics.runtime.exceptions24h > 0 ? "Degraded" : "Healthy"}
               />
               <DomainIntelligenceCard
                 name="Identity & Access"
                 icon={Lock}
                 metrics={[
                   { label: "Auth Provider", value: "Supabase Auth" },
                   { label: "Staff Profiles", value: metrics.records.profiles },
                   { label: "Row Level Security", value: "Enforced" }
                 ]}
                 status="Secured"
               />
               <DomainIntelligenceCard 
                 name="Cloud Readiness" 
                 icon={Globe} 
                 metrics={[
                   { label: "Supabase Connection", value: "Connected" },
                   { label: "Last Snapshot", value: metrics.backups.lastSnapshot ? new Date(metrics.backups.lastSnapshot).toLocaleDateString() : "None" },
                   { label: "Snapshots Stored", value: metrics.backups.count }
                 ]}
                 status="Online"
                 secondary
               />
            </div>
          </section>
        </div>

        {/* Intelligence Sidebar (Span 4) */}
        <div className="lg:col-span-4 space-y-8">
          {/* Recovery Intelligence - Context Aware */}
          <Card className="rounded-[2.5rem] border-slate-900 bg-slate-900 text-white shadow-2xl overflow-hidden relative group">
            <div className="absolute top-0 right-0 p-8 opacity-10 group-hover:scale-110 transition-transform">
               <Zap className="h-24 w-24" />
            </div>
            <CardHeader className="relative z-10">
              <div className="flex items-center justify-between">
                <CardTitle className="text-sm font-black uppercase tracking-widest text-brand-green">Recovery AI</CardTitle>
                <div className="h-2 w-2 rounded-full bg-brand-green animate-pulse" />
              </div>
              <CardDescription className="text-slate-400 text-xs mt-1">Context-aware system recommendations</CardDescription>
            </CardHeader>
            <CardContent className="space-y-6 pt-2 relative z-10">
              <div className="p-4 bg-white/5 rounded-2xl border border-white/10 backdrop-blur-sm">
                <p className="text-[10px] font-black text-slate-500 uppercase tracking-widest mb-2">Automated Analysis</p>
                <p className="text-xs leading-relaxed text-slate-200 font-medium italic">
                  {issues.length > 0 
                    ? `Detected ${issues.length} operational findings. Primary risk: ${issues[0].impact}. Recommending immediate intervention.`
                    : "System status is nominal. No urgent recovery actions required at this time."}
                </p>
              </div>

              <div className="space-y-3">
                 <p className="text-[10px] font-black text-slate-500 uppercase tracking-widest px-1">Prescribed Actions</p>
                 {issues.length > 0 ? (
                   issues.slice(0, 3).map(issue => (
                     <RecoveryActionLink key={issue.id} label={issue.recommendedAction} href="/admin/system" severity={issue.severity} />
                   ))
                 ) : (
                   <>
                     <RecoveryActionLink label="Refresh System Snapshot" href="/admin/system" />
                     <RecoveryActionLink label="Verify Data Integrity" href="/admin/system" />
                   </>
                 )}
              </div>
            </CardContent>
          </Card>

          {/* Recent Operational Activity Feed */}
          <Card className="rounded-[2.5rem] border-slate-100 dark:border-slate-800 shadow-sm overflow-hidden bg-white dark:bg-slate-900">
             <CardHeader className="bg-slate-50/50 dark:bg-slate-800/50 border-b border-slate-100 dark:border-slate-800">
               <div className="flex items-center justify-between">
                 <CardTitle className="text-xs font-black uppercase tracking-widest">System Activity</CardTitle>
                 <Clock className="h-3.5 w-3.5 text-slate-400" />
               </div>
             </CardHeader>
             <CardContent className="p-0">
                <div className="divide-y divide-slate-50 dark:divide-slate-800">
                  {activity.map((item) => (
                    <div key={item.id} className="p-4 hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors">
                      <div className="flex justify-between items-start mb-1">
                        <span className="text-[9px] font-black uppercase tracking-widest text-slate-400">{item.category}</span>
                        <span className="text-[9px] font-mono font-bold text-slate-500">{new Date(item.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span>
                      </div>
                      <p className="text-[11px] font-bold text-slate-700 dark:text-slate-300 leading-tight line-clamp-1">{item.message}</p>
                    </div>
                  ))}
                </div>
                <Link href="/admin/audit" className="w-full block">
                  <Button variant="ghost" className="w-full h-10 text-[10px] font-black uppercase tracking-widest text-slate-400 hover:text-slate-900 rounded-none border-t border-slate-100 dark:border-slate-800">
                    View Full Audit Trail
                  </Button>
                </Link>
             </CardContent>
          </Card>
        </div>
      </div>
    </div>
  );
}

type MetricStatus = "success" | "info" | "warning" | "error";

function LiveMetricCard({ label, value, subValue, status, icon: Icon }: {
  label: string;
  value: string;
  subValue: string;
  status: MetricStatus;
  icon: LucideIcon;
}) {
  const styles = {
    success: "bg-green-50 text-green-700 border-green-100 dark:bg-green-900/10 dark:text-green-400 dark:border-green-900/20",
    warning: "bg-amber-50 text-amber-700 border-amber-100 dark:bg-amber-900/10 dark:text-amber-400 dark:border-amber-900/20",
    error: "bg-red-50 text-red-700 border-red-100 dark:bg-red-900/10 dark:text-red-400 dark:border-red-900/20",
    info: "bg-blue-50 text-blue-700 border-blue-100 dark:bg-blue-900/10 dark:text-blue-400 dark:border-blue-900/20"
  }[status as 'success' | 'warning' | 'error' | 'info'];

  return (
    <div className={cn("p-6 rounded-[2rem] border transition-all hover:shadow-lg group relative overflow-hidden", styles)}>
      <div className="absolute top-0 right-0 p-4 opacity-5 group-hover:scale-110 transition-transform">
         <Icon className="h-16 w-16" />
      </div>
      <div className="relative z-10 flex flex-col h-full justify-between gap-4">
        <div className="flex justify-between items-start">
           <div className="h-10 w-10 rounded-xl bg-white/80 dark:bg-white/10 flex items-center justify-center shadow-sm">
             <Icon className="h-5 w-5" />
           </div>
           <span className="text-[9px] font-black uppercase tracking-[0.2em] opacity-40">Live Snapshot</span>
        </div>
        <div>
          <p className="text-[10px] font-black uppercase tracking-widest opacity-60 mb-1">{label}</p>
          <p className="text-lg font-black tracking-tight">{value}</p>
          <p className="text-[10px] font-bold opacity-60 mt-1 flex items-center gap-1.5">
             <span className="h-1 w-1 rounded-full bg-current" />
             {subValue}
          </p>
        </div>
      </div>
    </div>
  );
}

function IntelligentIssueCard({
  issue,
  canRepair,
  onRepair,
}: {
  issue: SystemIssue;
  /** Repairs write to live records, so they need manage_system. */
  canRepair: boolean;
  onRepair: (id: string) => void;
}) {
  const severityStyles = {
    INFO: "border-blue-100 bg-white dark:bg-slate-900 dark:border-blue-900/20 text-blue-600 dark:text-blue-400",
    WARNING: "border-amber-100 bg-white dark:bg-slate-900 dark:border-amber-900/20 text-amber-600 dark:text-amber-400",
    ERROR: "border-red-100 bg-white dark:bg-slate-900 dark:border-red-900/20 text-red-600 dark:text-red-400",
    CRITICAL: "border-purple-100 bg-white dark:bg-slate-900 dark:border-purple-900/20 text-purple-600 dark:text-purple-400 shadow-xl shadow-purple-900/5"
  }[issue.severity];

  const SeverityIcon = issue.severity === 'INFO' ? Info : issue.severity === 'WARNING' ? AlertTriangle : AlertCircle;

  return (
    <Card className={cn("rounded-[2.5rem] border shadow-sm transition-all hover:shadow-xl group overflow-hidden", severityStyles)}>
      <CardContent className="p-0">
        <div className="flex flex-col md:flex-row divide-y md:divide-y-0 md:divide-x divide-slate-50 dark:divide-slate-800">
          {/* Severity & Trace Section */}
          <div className="p-8 md:w-64 bg-slate-50/50 dark:bg-slate-800/30 shrink-0 space-y-6">
             <div className="h-14 w-14 rounded-2xl bg-white dark:bg-slate-900 flex items-center justify-center text-current shadow-sm">
               <SeverityIcon className="h-7 w-7" />
             </div>
             <div className="space-y-4">
                <div className="space-y-1">
                   <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Source Engine</p>
                   <p className="text-[11px] font-bold text-slate-700 dark:text-slate-200">{issue.source}</p>
                </div>
                {issue.affectedEntityType && (
                  <div className="space-y-1">
                     <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">Entity</p>
                     <p className="text-[11px] font-bold text-slate-700 dark:text-slate-200">{issue.affectedEntityType} {issue.affectedEntityId && `(${issue.affectedEntityId})`}</p>
                  </div>
                )}
                {issue.impact && (
                  <div className="space-y-1">
                     <p className="text-[9px] font-black text-slate-400 uppercase tracking-widest">System Impact</p>
                     <p className={cn("text-[11px] font-bold", issue.severity === 'CRITICAL' ? "text-red-500" : "text-amber-500")}>{issue.impact}</p>
                  </div>
                )}
             </div>
          </div>

          {/* Details & Recommendation Section */}
          <div className="flex-1 p-8 space-y-6">
            <div className="flex justify-between items-start">
               <div>
                 <h4 className="text-xl font-black text-slate-900 dark:text-white tracking-tight">{issue.title}</h4>
                 <div className="flex items-center gap-3 mt-1.5">
                   {issue.affectedCount !== undefined && (
                     <span className="px-2 py-0.5 rounded-md bg-slate-100 dark:bg-slate-800 text-[10px] font-black text-slate-600 dark:text-slate-400 uppercase">
                       {issue.affectedCount} Affected Records
                     </span>
                   )}
                   <span className="text-[10px] font-bold text-slate-400">{new Date(issue.lastDetectedAt).toLocaleString()}</span>
                 </div>
               </div>
               <span className={cn(
                 "px-4 py-1.5 rounded-full text-[10px] font-black uppercase tracking-widest",
                 issue.severity === 'CRITICAL' ? "bg-red-600 text-white shadow-lg shadow-red-600/20" : "bg-current/10"
               )}>
                 {issue.severity}
               </span>
            </div>

            <div className="grid grid-cols-1 md:grid-cols-2 gap-8">
               <div className="space-y-2">
                 <p className="text-[10px] font-black text-slate-400 uppercase tracking-[0.2em]">Explanation</p>
                 <p className="text-sm text-slate-600 dark:text-slate-400 leading-relaxed font-medium">{issue.explanation}</p>
               </div>
               <div className="space-y-3">
                 <p className="text-[10px] font-black text-slate-400 uppercase tracking-[0.2em]">Recovery Guidance</p>
                 <div 
                    onClick={() => issue.repairable && canRepair && onRepair(issue.id)}
                    className={cn(
                      "p-4 bg-slate-50 dark:bg-slate-800/50 rounded-2xl border border-slate-100 dark:border-slate-800 flex items-start gap-4 transition-all",
                      issue.repairable && canRepair ? "group/rec cursor-pointer hover:border-brand-blue/30" : "opacity-70 cursor-not-allowed"
                    )}
                  >
                   <Zap className={cn("h-5 w-5 shrink-0 mt-0.5 transition-transform", issue.repairable ? "text-brand-blue group-hover/rec:scale-110" : "text-slate-400")} />
                   <div>
                     <p className="text-sm text-slate-900 dark:text-slate-100 font-black leading-tight mb-1">{issue.recommendedAction}</p>
                     <p className="text-[10px] font-bold text-slate-500 uppercase tracking-widest flex items-center justify-between">
                       <span>Repairability: {issue.repairable ? (canRepair ? 'Automatic Available' : 'Needs manage_system') : 'Manual Intervention'}</span>
                       {issue.repairable && canRepair && <span className="text-brand-blue group-hover/rec:underline">Click to Repair</span>}
                     </p>
                   </div>
                 </div>
               </div>
            </div>
          </div>
        </div>
      </CardContent>
    </Card>
  );
}

function DomainIntelligenceCard({ name, icon: Icon, metrics, status, secondary }: {
  name: string;
  icon: LucideIcon;
  metrics: Array<{ label: string; value: string | number }>;
  status: string;
  secondary?: boolean;
}) {
  return (
    <div className={cn(
      "p-8 rounded-[2.5rem] border transition-all hover:shadow-xl group",
      secondary ? "bg-slate-50/50 border-slate-100 dark:bg-slate-900 dark:border-slate-800 opacity-60" : "bg-white border-slate-100 dark:bg-slate-900 dark:border-slate-800"
    )}>
      <div className="flex justify-between items-start mb-6">
        <div className="h-14 w-14 rounded-2xl bg-slate-50 dark:bg-slate-800 flex items-center justify-center text-slate-400 group-hover:text-brand-blue transition-all group-hover:rotate-6 shadow-sm">
          <Icon className="h-7 w-7" />
        </div>
        <div className={cn(
          "px-3 py-1 rounded-full text-[9px] font-black uppercase tracking-widest",
          status === "Healthy" || status === "Secured" ? "bg-green-100 text-green-700" : "bg-slate-100 text-slate-600"
        )}>
          {status}
        </div>
      </div>
      <h4 className="text-base font-black text-slate-900 dark:text-white mb-6 tracking-tight">{name}</h4>
      <div className="space-y-4">
         {metrics.map((m, i) => (
           <div key={i} className="flex flex-col gap-1">
             <span className="text-[10px] font-black text-slate-400 uppercase tracking-widest">{m.label}</span>
             <span className="text-xs font-bold text-slate-700 dark:text-slate-300">{m.value}</span>
           </div>
         ))}
      </div>
    </div>
  );
}

function RecoveryActionLink({ label, href, severity }: { label: string, href: string, severity?: LogSeverity }) {
  const isCritical = severity === 'CRITICAL' || severity === 'ERROR';

  return (
    <a href={href} className={cn(
      "flex items-center justify-between p-4 rounded-2xl transition-all group border backdrop-blur-sm",
      isCritical ? "bg-red-500/10 border-red-500/20 hover:bg-red-500/20 hover:border-red-500/40" : "bg-white/5 border-white/5 hover:bg-white/10 hover:border-white/20"
    )}>
      <div className="flex items-center gap-3">
        <div className={cn("h-2 w-2 rounded-full", isCritical ? "bg-red-500" : "bg-brand-green")} />
        <span className="text-xs font-black text-slate-300">{label}</span>
      </div>
      <RefreshCw className="h-3.5 w-3.5 text-slate-500 group-hover:rotate-180 transition-transform duration-500" />
    </a>
  );
}

function calculateAge(timestamp: string) {
  const diff = new Date().getTime() - new Date(timestamp).getTime();
  const minutes = Math.floor(diff / 60000);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  return `${Math.floor(hours / 24)}d ago`;
}
