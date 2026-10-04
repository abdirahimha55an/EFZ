"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { SystemLog, LogSeverity, LogCategory, AdminUser } from "@/lib/types";
import { getDb, describeDbError } from "@/lib/supabase/db";
import { NO_AUDIT_USER, type AuditLogFilter } from "@/lib/supabase/queries";
import { derivePermissions } from "@/lib/permissions";
import { Search, Shield, AlertTriangle, Info, AlertCircle, Clock, Database, User, Loader2, RefreshCcw, FileSpreadsheet, ChevronLeft, ChevronRight, ChevronDown } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";
import { efzDateRange, efzToday, formatEfzDateTime, type EfzDatePreset } from "@/lib/dates";
import { auditDetailsText, auditExportFileName, buildAuditWorkbook } from "@/lib/auditExport";

/**
 * Who wrote an audit line (system_logs.origin, set by the database since
 * migration 11). Only "database" lines are written by the database in the
 * same transaction as the action; a browser line's actor and time are stamped
 * by the database but its text is the browser's.
 */
const ORIGIN_BADGE: Record<'database' | 'client' | 'unknown', { label: string; title: string; style: string }> = {
  database: {
    label: 'Database',
    title: 'Recorded by the database in the same transaction as the action.',
    style: 'bg-emerald-50 text-emerald-700 border-emerald-100 dark:bg-emerald-900/10 dark:text-emerald-400 dark:border-emerald-900/20',
  },
  client: {
    label: 'Browser',
    title: "Sent by a signed-in user's browser. Who and when are stamped by the database; the text is not verified.",
    style: 'bg-amber-50 text-amber-700 border-amber-100 dark:bg-amber-900/10 dark:text-amber-400 dark:border-amber-900/20',
  },
  unknown: {
    label: 'Unverified',
    title: 'Written before the database recorded where audit lines come from.',
    style: 'bg-slate-50 text-slate-500 border-slate-100 dark:bg-slate-800 dark:text-slate-400 dark:border-slate-700',
  },
};

/**
 * The audit trail is append-only and grows without bound: every filter runs in
 * the database and the result is paged, so nothing depends on what happens to
 * be loaded in the browser.
 */
const PAGE_SIZE = 50;

const CATEGORIES: LogCategory[] = ['AUTH', 'CUSTOMER', 'FINANCIAL', 'INVENTORY', 'ORDER', 'PRODUCT', 'SECURITY', 'STORAGE', 'SYSTEM'];
const SEVERITIES: LogSeverity[] = ['INFO', 'WARNING', 'ERROR', 'CRITICAL'];
const DATE_PRESETS: { value: EfzDatePreset; label: string }[] = [
  { value: 'all', label: 'All time' },
  { value: 'today', label: 'Today' },
  { value: 'yesterday', label: 'Yesterday' },
  { value: 'last7', label: 'Last 7 days' },
  { value: 'last30', label: 'Last 30 days' },
  { value: 'date', label: 'Single date' },
  { value: 'custom', label: 'Custom range' },
];

type Summary = { total: number; failedLogins: number; privilegeChanges: number; payouts: number; critical: number };

export default function AuditTrailPage() {
  const [logs, setLogs] = useState<SystemLog[]>([]);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  const [staff, setStaff] = useState<AdminUser[]>([]);
  const [isLoading, setIsLoading] = useState(true);
  const [isFetching, setIsFetching] = useState(false);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [exportState, setExportState] = useState<{ busy: boolean; message: string | null; error: boolean }>({ busy: false, message: null, error: false });
  const [expanded, setExpanded] = useState<string | null>(null);
  const [reloadKey, setReloadKey] = useState(0);

  // Filters
  const [searchInput, setSearchInput] = useState("");
  const [searchTerm, setSearchTerm] = useState("");
  const [categoryFilter, setCategoryFilter] = useState<string>("ALL");
  const [severityFilter, setSeverityFilter] = useState<string>("ALL");
  const [userFilter, setUserFilter] = useState<string>("ALL");
  const [datePreset, setDatePreset] = useState<EfzDatePreset>("all");
  const [fromDate, setFromDate] = useState("");
  const [toDate, setToDate] = useState("");
  const [page, setPage] = useState(0);

  const canViewAudit = derivePermissions(currentUser).viewAuditTrail;

  // Typing in the search box queries the database once the user pauses.
  useEffect(() => {
    const timer = window.setTimeout(() => setSearchTerm(searchInput.trim()), 300);
    return () => window.clearTimeout(timer);
  }, [searchInput]);

  const range = useMemo(
    () => efzDateRange(datePreset, { from: fromDate, to: datePreset === 'date' ? fromDate : toDate }),
    [datePreset, fromDate, toDate]
  );

  const filter = useMemo<AuditLogFilter>(() => ({
    search: searchTerm || undefined,
    category: categoryFilter === "ALL" ? undefined : (categoryFilter as LogCategory),
    severity: severityFilter === "ALL" ? undefined : (severityFilter as LogSeverity),
    userId: userFilter === "ALL" ? undefined : userFilter,
    range: range ?? undefined,
  }), [searchTerm, categoryFilter, severityFilter, userFilter, range]);

  // Any filter change starts again at the first page.
  const filterKey = JSON.stringify(filter);
  const lastFilterKey = useRef(filterKey);
  useEffect(() => {
    if (lastFilterKey.current !== filterKey) {
      lastFilterKey.current = filterKey;
      setPage(0);
      setExpanded(null);
      setExportState({ busy: false, message: null, error: false });
    }
  }, [filterKey]);

  // Who is signed in (and the staff list for the user filter).
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const db = getDb();
        const me = await db.auth.getProfile();
        if (cancelled) return;
        setCurrentUser(me);
        if (derivePermissions(me).viewAuditTrail) {
          try {
            const users = await db.users.list();
            if (!cancelled) setStaff(users);
          } catch {
            // The user filter simply offers no names.
          }
        }
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsLoading(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // The page of audit lines and the summary figures for the current filters.
  useEffect(() => {
    // Asking without view_audit_trail is an RLS refusal, so don't ask.
    if (!currentUser || !canViewAudit) return;
    let cancelled = false;
    (async () => {
      setIsFetching(true);
      try {
        const db = getDb();
        const [result, failedLogins, privilegeChanges, payouts, critical] = await Promise.all([
          db.logs.search(filter, { offset: page * PAGE_SIZE, limit: PAGE_SIZE }),
          db.logs.countWhere(filter, { category: 'AUTH', severities: ['WARNING'] }),
          db.logs.countWhere(filter, { messageLike: ['permission', 'role'] }),
          db.logs.countWhere(filter, { category: 'FINANCIAL', messageLike: ['payout'] }),
          db.logs.countWhere(filter, { severities: ['CRITICAL', 'ERROR'] }),
        ]);
        if (cancelled) return;
        setLogs(result.rows);
        setSummary({ total: result.total, failedLogins, privilegeChanges, payouts, critical });
        setLoadError(null);
      } catch (error) {
        if (!cancelled) setLoadError(describeDbError(error));
      } finally {
        if (!cancelled) setIsFetching(false);
      }
    })();
    return () => { cancelled = true; };
  }, [currentUser, canViewAudit, filter, page, reloadKey]);

  /** Every line matching the current filters (not just this page), as an .xlsx file. */
  const exportExcel = useCallback(async () => {
    setExportState({ busy: true, message: null, error: false });
    try {
      const db = getDb();
      const rows = await db.logs.exportAll(filter);
      if (rows.length === 0) {
        setExportState({ busy: false, message: "No audit events match these filters, so there is nothing to export.", error: false });
        return;
      }
      const bytes = buildAuditWorkbook(rows);
      const fileName = auditExportFileName(range);
      // Exporting the audit trail is itself recorded, and the record is written
      // BEFORE the file is handed over: an export that cannot be recorded does
      // not happen, and closing the tab right after the download cannot skip it.
      try {
        await db.logs.write({
          category: 'SECURITY',
          severity: 'INFO',
          message: `Audit trail exported to Excel: ${rows.length} event(s)`,
          metadata: { fileName, events: rows.length, filter: { ...filter } },
        });
      } catch (error) {
        setExportState({ busy: false, message: `Export cancelled: the export could not be recorded in the audit trail (${describeDbError(error)}). Nothing was downloaded.`, error: true });
        return;
      }
      const blob = new Blob([bytes as BlobPart], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" });
      const url = URL.createObjectURL(blob);
      const anchor = document.createElement("a");
      anchor.href = url;
      anchor.download = fileName;
      document.body.appendChild(anchor);
      anchor.click();
      anchor.remove();
      window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      setExportState({ busy: false, message: `Exported ${rows.length.toLocaleString()} event(s) to ${fileName}.`, error: false });
    } catch (error) {
      setExportState({ busy: false, message: describeDbError(error), error: true });
    }
  }, [filter, range]);

  if (isLoading) {
    return (
      <div className="flex flex-col items-center justify-center gap-3 py-32 text-slate-400">
        <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        <p className="text-xs font-medium">Loading audit trail…</p>
      </div>
    );
  }

  if (!currentUser || !canViewAudit) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[60vh] space-y-4">
        <Shield className="h-16 w-16 text-slate-300" />
        <h2 className="text-xl font-bold text-slate-700">Access Denied</h2>
        <p className="text-slate-500">You do not have permission to view the audit trail.</p>
      </div>
    );
  }

  const getSeverityIcon = (severity: LogSeverity) => {
    switch (severity) {
      case 'CRITICAL': return <AlertCircle className="h-4 w-4 text-purple-500" />;
      case 'ERROR': return <AlertCircle className="h-4 w-4 text-red-500" />;
      case 'WARNING': return <AlertTriangle className="h-4 w-4 text-amber-500" />;
      case 'INFO': return <Info className="h-4 w-4 text-blue-500" />;
      default: return <Info className="h-4 w-4 text-slate-500" />;
    }
  };

  const getSeverityStyle = (severity: LogSeverity) => {
    switch (severity) {
      case 'CRITICAL': return "bg-purple-50 text-purple-700 border-purple-100 dark:bg-purple-900/10 dark:text-purple-400 dark:border-purple-900/20";
      case 'ERROR': return "bg-red-50 text-red-700 border-red-100 dark:bg-red-900/10 dark:text-red-400 dark:border-red-900/20";
      case 'WARNING': return "bg-amber-50 text-amber-700 border-amber-100 dark:bg-amber-900/10 dark:text-amber-400 dark:border-amber-900/20";
      case 'INFO': return "bg-blue-50 text-blue-700 border-blue-100 dark:bg-blue-900/10 dark:text-blue-400 dark:border-blue-900/20";
      default: return "bg-slate-50 text-slate-700 border-slate-100 dark:bg-slate-800 dark:text-slate-400 dark:border-slate-700";
    }
  };

  const total = summary?.total ?? 0;
  const pageCount = Math.max(1, Math.ceil(total / PAGE_SIZE));
  const firstShown = total === 0 ? 0 : page * PAGE_SIZE + 1;
  const lastShown = Math.min(total, (page + 1) * PAGE_SIZE);
  const selectClass = "h-10 px-3 bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 rounded-xl text-xs font-bold text-slate-700 dark:text-slate-300 outline-none";
  const rangeLabel = range ? (range.from === range.to ? range.from : `${range.from} to ${range.to}`) : "all dates";

  return (
    <div className="space-y-8 animate-in fade-in duration-500 pb-20">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-6">
        <div className="space-y-1">
          <div className="flex items-center gap-3">
             <div className="h-10 w-10 rounded-2xl bg-slate-900 flex items-center justify-center text-brand-blue">
               <Database className="h-5 w-5" />
             </div>
             <h1 className="text-3xl font-black text-slate-900 dark:text-white tracking-tight">Audit Trail</h1>
          </div>
          <p className="text-slate-500 dark:text-slate-400 font-medium pl-1">
            Comprehensive immutable log of all system activities and administrative actions. Times are Mogadishu time (EAT).
          </p>
        </div>
        <div className="flex gap-2">
          <Button onClick={() => setReloadKey(k => k + 1)} disabled={isFetching} variant="outline" className="rounded-2xl px-5 h-12 font-bold border-slate-200 text-slate-500">
            <RefreshCcw className={cn("h-4 w-4 mr-2", isFetching && "animate-spin")} /> Refresh
          </Button>
          <Button
            data-testid="audit-export"
            onClick={exportExcel}
            disabled={exportState.busy || isFetching || total === 0}
            title={total === 0 ? "No audit events match these filters" : `Export all ${total.toLocaleString()} matching event(s), not just this page`}
            className="bg-slate-900 text-white hover:bg-slate-800 rounded-2xl px-6 h-12 font-bold shadow-xl"
          >
            {exportState.busy ? <Loader2 className="h-4 w-4 mr-2 animate-spin" /> : <FileSpreadsheet className="h-4 w-4 mr-2" />}
            Export Excel
          </Button>
        </div>
      </div>

      {exportState.message && (
        <p data-testid="audit-export-message" className={cn("rounded-xl border px-4 py-2 text-xs font-medium", exportState.error ? "border-red-200 bg-red-50 text-red-700" : "border-slate-200 bg-slate-50 text-slate-600")}>
          {exportState.message}
        </p>
      )}

      {/* Summary Cards: counted in the database over everything matching the filters */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Matching Events</span>
          <span data-testid="audit-total" className="text-2xl font-black text-slate-900 dark:text-white">{summary ? summary.total.toLocaleString() : "—"}</span>
        </div>
        {/* A failed sign-in cannot be written here: the caller is not
            authenticated and the insert policy is authenticated-only. Supabase
            Auth keeps its own record of them. */}
        <div
          className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24"
          title="Failed sign-ins are recorded by Supabase Auth, not in this table. Check Authentication → Logs in the Supabase dashboard."
        >
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Failed Logins</span>
          <span className="text-2xl font-black text-amber-500">{summary ? summary.failedLogins : "—"}</span>
          <span className="text-[9px] font-medium text-slate-400 leading-tight">Tracked in Supabase Auth</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Privilege Changes</span>
          <span className="text-2xl font-black text-brand-blue">{summary ? summary.privilegeChanges : "—"}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Payouts Processed</span>
          <span className="text-2xl font-black text-brand-green">{summary ? summary.payouts : "—"}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Critical Events</span>
          <span className="text-2xl font-black text-red-500">{summary ? summary.critical : "—"}</span>
        </div>
      </div>

      <Card className="border-none shadow-sm overflow-hidden bg-white dark:bg-slate-900 rounded-[2rem]">
        {/* Toolbar */}
        <div className="p-4 border-b border-slate-100 dark:border-slate-800 space-y-3 bg-slate-50/50 dark:bg-slate-800/30">
          <div className="flex flex-col md:flex-row gap-3 md:items-center">
            <div className="relative w-full md:w-96">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
              <Input
                data-testid="audit-search"
                placeholder="Search logs, usernames, or target IDs..."
                className="pl-10 h-10 bg-white dark:bg-slate-900 border-slate-200 dark:border-slate-700 rounded-xl text-xs font-medium"
                value={searchInput}
                onChange={e => setSearchInput(e.target.value)}
              />
            </div>
            <div className="flex flex-wrap gap-2">
              <select data-testid="audit-category" className={selectClass} value={categoryFilter} onChange={e => setCategoryFilter(e.target.value)}>
                <option value="ALL">All Categories</option>
                {CATEGORIES.map(c => <option key={c} value={c}>{c}</option>)}
              </select>
              <select data-testid="audit-severity" className={selectClass} value={severityFilter} onChange={e => setSeverityFilter(e.target.value)}>
                <option value="ALL">All Severities</option>
                {SEVERITIES.map(s => <option key={s} value={s}>{s}</option>)}
              </select>
              <select data-testid="audit-user" className={selectClass} value={userFilter} onChange={e => setUserFilter(e.target.value)}>
                <option value="ALL">All Users</option>
                <option value={NO_AUDIT_USER}>System (no user)</option>
                {[...staff].sort((a, b) => a.name.localeCompare(b.name)).map(u => <option key={u.id} value={u.id}>{u.name}</option>)}
              </select>
              <select data-testid="audit-date-preset" className={selectClass} value={datePreset} onChange={e => setDatePreset(e.target.value as EfzDatePreset)}>
                {DATE_PRESETS.map(p => <option key={p.value} value={p.value}>{p.label}</option>)}
              </select>
            </div>
          </div>
          {(datePreset === 'date' || datePreset === 'custom') && (
            <div className="flex flex-wrap items-center gap-2 text-xs font-bold text-slate-500">
              <label className="flex items-center gap-2">
                {datePreset === 'date' ? 'Date' : 'From'}
                <input data-testid="audit-date-from" type="date" max={efzToday()} className={selectClass} value={fromDate} onChange={e => setFromDate(e.target.value)} />
              </label>
              {datePreset === 'custom' && (
                <label className="flex items-center gap-2">
                  To
                  <input data-testid="audit-date-to" type="date" max={efzToday()} className={selectClass} value={toDate} onChange={e => setToDate(e.target.value)} />
                </label>
              )}
              <span className="font-medium text-slate-400">Whole days, Mogadishu time (EAT).</span>
            </div>
          )}
        </div>

        {/* Table */}
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="text-[10px] text-slate-400 uppercase font-black tracking-widest bg-white dark:bg-slate-900 border-b border-slate-100 dark:border-slate-800">
                <tr>
                  <th className="px-6 py-4">Date &amp; Time (EAT)</th>
                  <th className="px-6 py-4">Severity</th>
                  <th className="px-6 py-4">Category</th>
                  <th className="px-6 py-4">Action Details</th>
                  <th className="px-6 py-4">Target ID</th>
                </tr>
              </thead>
              <tbody className={cn("divide-y divide-slate-50 dark:divide-slate-800/50", isFetching && "opacity-60")}>
                {logs.map(log => {
                  const details = auditDetailsText(log);
                  const isOpen = expanded === log.id;
                  return (
                    <tr key={log.id} data-testid="audit-row" className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors group align-top">
                      <td className="px-6 py-4 whitespace-nowrap">
                        <div className="flex items-center gap-2">
                          <Clock className="h-3.5 w-3.5 text-slate-400" />
                          <span className="font-mono text-slate-600 dark:text-slate-400" data-testid="audit-time" data-ts={log.timestamp}>
                            {formatEfzDateTime(log.timestamp)}
                          </span>
                        </div>
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap">
                        <div className={cn("inline-flex items-center gap-1.5 px-2.5 py-1 rounded-md border text-[10px] font-black uppercase tracking-widest", getSeverityStyle(log.severity))}>
                          {getSeverityIcon(log.severity)}
                          {log.severity}
                        </div>
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap">
                        <span className="text-[10px] font-black uppercase tracking-widest text-slate-500 bg-slate-100 dark:bg-slate-800 px-2 py-1 rounded-md">
                          {log.category}
                        </span>
                      </td>
                      <td className="px-6 py-4 min-w-[300px]">
                        <p className="font-bold text-slate-900 dark:text-slate-100">{log.message}</p>
                        <div className="mt-1 flex flex-wrap items-center gap-2">
                          {(() => {
                            const badge = ORIGIN_BADGE[log.origin ?? 'unknown'];
                            return (
                              <span title={badge.title} className={cn("inline-flex items-center rounded border px-1.5 py-0.5 text-[9px] font-black uppercase tracking-widest", badge.style)}>
                                {badge.label}
                              </span>
                            );
                          })()}
                          {(log.username || log.userId) && (
                            <p className="text-[10px] font-bold text-slate-500 uppercase tracking-widest flex items-center gap-1">
                              <User className="h-3 w-3" /> By {log.username || log.userId}
                            </p>
                          )}
                          {details && (
                            <button
                              type="button"
                              data-testid="audit-details-toggle"
                              onClick={() => setExpanded(isOpen ? null : log.id)}
                              className="inline-flex items-center gap-1 text-[10px] font-bold uppercase tracking-widest text-brand-blue"
                            >
                              <ChevronDown className={cn("h-3 w-3 transition-transform", isOpen && "rotate-180")} /> Details
                            </button>
                          )}
                        </div>
                        {details && isOpen && (
                          <pre data-testid="audit-details" className="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-all rounded-lg bg-slate-50 p-2 font-mono text-[10px] text-slate-600 dark:bg-slate-800 dark:text-slate-300">
                            {details}
                          </pre>
                        )}
                      </td>
                      <td className="px-6 py-4 whitespace-nowrap">
                        {log.targetId ? (
                          <span className="font-mono text-[10px] font-bold text-brand-blue bg-blue-50 dark:bg-blue-900/10 px-2 py-1 rounded border border-blue-100 dark:border-blue-900/20">
                            {log.targetId}
                          </span>
                        ) : (
                          <span className="text-slate-300 dark:text-slate-700">-</span>
                        )}
                      </td>
                    </tr>
                  );
                })}
                {!isFetching && summary && logs.length === 0 && (
                  <tr>
                    <td colSpan={5} className="px-6 py-12 text-center" data-testid="audit-empty">
                      <div className="flex flex-col items-center justify-center space-y-3">
                        <Search className="h-8 w-8 text-slate-300" />
                        <p className="text-slate-500 font-medium">No audit events match your filters ({rangeLabel}).</p>
                      </div>
                    </td>
                  </tr>
                )}
                {loadError && (
                  <tr>
                    <td colSpan={5} className="px-6 py-6 text-center text-red-600" data-testid="audit-error">
                      Could not load the audit trail: {loadError}
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>

          {/* Pagination */}
          <div className="flex items-center justify-between gap-3 border-t border-slate-100 dark:border-slate-800 px-6 py-3 text-xs text-slate-500">
            <span data-testid="audit-page-info">
              {total === 0 ? "No events" : `${firstShown.toLocaleString()}–${lastShown.toLocaleString()} of ${total.toLocaleString()} events · page ${page + 1} of ${pageCount}`}
            </span>
            <div className="flex gap-2">
              <Button data-testid="audit-prev" variant="outline" size="sm" className="h-8 rounded-lg" disabled={page === 0 || isFetching} onClick={() => setPage(p => Math.max(0, p - 1))}>
                <ChevronLeft className="h-3.5 w-3.5" /> Previous
              </Button>
              <Button data-testid="audit-next" variant="outline" size="sm" className="h-8 rounded-lg" disabled={page + 1 >= pageCount || isFetching} onClick={() => setPage(p => p + 1)}>
                Next <ChevronRight className="h-3.5 w-3.5" />
              </Button>
            </div>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
