"use client";

import { useCallback, useEffect, useState } from "react";
import { Database, AlertTriangle, Cloud } from "lucide-react";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { cn } from "@/lib/utils";
import { useRouter } from "next/navigation";

type Status = "CHECKING" | "CONNECTED" | "ISSUES" | "BACKUP_NEEDED" | "ERROR";

export function SystemStatusBadge() {
  const router = useRouter();
  // Starts at CHECKING rather than guessing CONNECTED, so the badge never
  // claims a healthy database before it has asked one.
  const [status, setStatus] = useState<Status>("CHECKING");
  const [tooltip, setTooltip] = useState("Checking system status…");

  /**
   * Reports the state of the database, not the browser.
   *
   * This used to read the localStorage quota and say "Local Mode". There is no
   * local store left to be healthy or unhealthy, so it now surfaces what the
   * diagnostics scan and the backup history actually say.
   */
  const checkStatus = useCallback(async () => {
    try {
      const metrics = await getDb().issues.metrics();

      if (metrics.issues.critical > 0) {
        setStatus("ERROR");
        setTooltip(`${metrics.issues.critical} critical finding(s) need attention`);
        return;
      }

      if (metrics.issues.open > 0) {
        setStatus("ISSUES");
        setTooltip(`${metrics.issues.open} open finding(s) — health ${metrics.health.score}/100`);
        return;
      }

      const lastSnapshot = metrics.backups.lastSnapshot;
      if (!lastSnapshot) {
        setStatus("BACKUP_NEEDED");
        setTooltip("No snapshot recorded yet. Export one from System Management.");
        return;
      }

      const daysSince = (Date.now() - new Date(lastSnapshot).getTime()) / (1000 * 3600 * 24);
      if (daysSince > 7) {
        setStatus("BACKUP_NEEDED");
        setTooltip("Your last snapshot is over 7 days old.");
        return;
      }

      setStatus("CONNECTED");
      setTooltip(`Connected to Supabase — health ${metrics.health.score}/100`);
    } catch (error) {
      setStatus("ERROR");
      setTooltip(describeDbError(error));
    }
  }, []);

  useEffect(() => {
    let cancelled = false;

    const tick = async () => {
      if (!cancelled) await checkStatus();
    };

    void tick();
    const interval = setInterval(() => void tick(), 30000); // Check every 30s

    return () => {
      cancelled = true;
      clearInterval(interval);
    };
  }, [checkStatus]);

  const config = {
    CHECKING: {
      label: "Checking",
      color: "bg-slate-100 dark:bg-slate-800 text-slate-500 dark:text-slate-400 border-slate-200 dark:border-slate-700",
      dot: "bg-slate-400",
      icon: Cloud
    },
    CONNECTED: {
      label: "Connected",
      color: "bg-emerald-50 dark:bg-emerald-950/30 text-emerald-600 dark:text-emerald-400 border-emerald-100 dark:border-emerald-900/50 hover:bg-emerald-100 dark:hover:bg-emerald-900/40",
      dot: "bg-emerald-500",
      icon: Cloud
    },
    ISSUES: {
      label: "Open Findings",
      color: "bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400 border-amber-100 dark:border-amber-900/50 shadow-sm shadow-amber-100/50 hover:bg-amber-100 dark:hover:bg-amber-900/40",
      dot: "bg-amber-500",
      icon: AlertTriangle
    },
    BACKUP_NEEDED: {
      label: "Backup Needed",
      color: "bg-amber-50 dark:bg-amber-950/30 text-amber-600 dark:text-amber-400 border-amber-100 dark:border-amber-900/50 shadow-sm shadow-amber-100/50 hover:bg-amber-100 dark:hover:bg-amber-900/40",
      dot: "bg-amber-500",
      icon: Database
    },
    ERROR: {
      label: "Attention",
      color: "bg-red-50 dark:bg-red-950/30 text-red-600 dark:text-red-400 border-red-100 dark:border-red-900/50 animate-bounce-subtle hover:bg-red-100 dark:hover:bg-red-900/40",
      dot: "bg-red-500",
      icon: Database
    }
  }[status];

  const Icon = config.icon;

  return (
    <div className="group relative">
      <button 
        onClick={() => router.push('/admin/diagnostics')}
        className={cn(
          "flex items-center gap-2 px-3 py-1.5 rounded-full border text-[10px] font-bold uppercase tracking-wider transition-all duration-300 cursor-pointer active:scale-95",
          config.color
        )}
      >
        <div className={cn("w-1.5 h-1.5 rounded-full", config.dot, status !== "CONNECTED" && "animate-pulse")} />
        <Icon className="h-3 w-3" />
        <span>{config.label}</span>
      </button>
      
      {/* Premium Tooltip */}
      <div className="absolute top-full left-1/2 -translate-x-1/2 mt-2 px-3 py-2 bg-slate-900 text-white text-[10px] rounded-lg opacity-0 group-hover:opacity-100 transition-all duration-200 pointer-events-none whitespace-nowrap z-[100] shadow-2xl border border-slate-800 font-medium scale-95 group-hover:scale-100">
        <div className="relative z-10 flex items-center gap-2">
          {status === 'ERROR' && <Database className="h-3 w-3 text-red-400" />}
          {(status === 'BACKUP_NEEDED' || status === 'ISSUES') && <AlertTriangle className="h-3 w-3 text-amber-400" />}
          {status === 'CONNECTED' && <ShieldCheckIcon className="h-3 w-3 text-emerald-400" />}
          {tooltip}
          <span className="ml-2 text-slate-500 text-[9px] border-l border-slate-700 pl-2">View Diagnostics</span>
        </div>
        <div className="absolute -top-1 left-1/2 -translate-x-1/2 border-4 border-transparent border-b-slate-900" />
      </div>
    </div>
  );
}

// Sub-icon for tooltip
function ShieldCheckIcon({ className }: { className?: string }) {
  return (
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" className={className}>
      <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10" />
      <path d="m9 12 2 2 4-4" />
    </svg>
  );
}
