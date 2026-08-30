"use client";

import { useState, useEffect, useMemo } from "react";
import { storage, SystemLog, LogSeverity, LogCategory, AdminUser } from "@/lib/storage";
import { Search, Filter, Shield, AlertTriangle, Info, AlertCircle, Clock, Trash2, Database, User } from "lucide-react";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { cn } from "@/lib/utils";

export default function AuditTrailPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [logs, setLogs] = useState<SystemLog[]>([]);
  const [currentUser, setCurrentUser] = useState<AdminUser | null>(null);
  
  // Filters
  const [searchTerm, setSearchTerm] = useState("");
  const [categoryFilter, setCategoryFilter] = useState<string>("ALL");
  const [severityFilter, setSeverityFilter] = useState<string>("ALL");

  useEffect(() => {
    setIsMounted(true);
    setCurrentUser(storage.getProfile());
    setLogs(storage.logger.getLogs());
  }, []);

  if (!isMounted || !currentUser) return null;

  // Permission Check
  const canViewAudit = storage.canViewAuditTrail(currentUser);

  if (!canViewAudit) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[60vh] space-y-4">
        <Shield className="h-16 w-16 text-slate-300" />
        <h2 className="text-xl font-bold text-slate-700">Access Denied</h2>
        <p className="text-slate-500">You do not have permission to view the audit trail.</p>
      </div>
    );
  }

  const filteredLogs = logs.filter(log => {
    const matchesSearch = 
      log.message.toLowerCase().includes(searchTerm.toLowerCase()) ||
      (log.userId && log.userId.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (log.username && log.username.toLowerCase().includes(searchTerm.toLowerCase())) ||
      (log.targetId && log.targetId.toLowerCase().includes(searchTerm.toLowerCase()));
      
    const matchesCategory = categoryFilter === "ALL" || log.category === categoryFilter;
    const matchesSeverity = severityFilter === "ALL" || log.severity === severityFilter;

    return matchesSearch && matchesCategory && matchesSeverity;
  });

  const categories = Array.from(new Set(logs.map(l => l.category)));
  const severities = Array.from(new Set(logs.map(l => l.severity)));

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

  const exportLogs = () => {
    const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(logs, null, 2));
    const downloadAnchorNode = document.createElement('a');
    downloadAnchorNode.setAttribute("href", dataStr);
    downloadAnchorNode.setAttribute("download", `audit_log_${new Date().toISOString().split('T')[0]}.json`);
    document.body.appendChild(downloadAnchorNode);
    downloadAnchorNode.click();
    downloadAnchorNode.remove();
  };

  const summary = {
    total: logs.length,
    failedLogins: logs.filter(l => l.category === 'AUTH' && l.severity === 'WARNING').length,
    privilegeChanges: logs.filter(l => l.message.toLowerCase().includes('permission') || l.message.toLowerCase().includes('role')).length,
    payouts: logs.filter(l => l.category === 'FINANCIAL' && l.message.toLowerCase().includes('payout')).length,
    critical: logs.filter(l => l.severity === 'CRITICAL' || l.severity === 'ERROR').length
  };

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
            Comprehensive immutable log of all system activities and administrative actions.
          </p>
        </div>
        <Button onClick={exportLogs} className="bg-slate-900 text-white hover:bg-slate-800 rounded-2xl px-6 h-12 font-bold shadow-xl">
          Export to JSON
        </Button>
      </div>

      {/* Summary Cards */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Total Events</span>
          <span className="text-2xl font-black text-slate-900 dark:text-white">{summary.total}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Failed Logins</span>
          <span className="text-2xl font-black text-amber-500">{summary.failedLogins}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Privilege Changes</span>
          <span className="text-2xl font-black text-brand-blue">{summary.privilegeChanges}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Payouts Processed</span>
          <span className="text-2xl font-black text-brand-green">{summary.payouts}</span>
        </div>
        <div className="bg-white dark:bg-slate-900 p-4 rounded-2xl border border-slate-100 dark:border-slate-800 flex flex-col justify-between h-24">
          <span className="text-[10px] font-black uppercase tracking-widest text-slate-400">Critical Events</span>
          <span className="text-2xl font-black text-red-500">{summary.critical}</span>
        </div>
      </div>

      <Card className="border-none shadow-sm overflow-hidden bg-white dark:bg-slate-900 rounded-[2rem]">
        {/* Toolbar */}
        <div className="p-4 border-b border-slate-100 dark:border-slate-800 flex flex-col md:flex-row gap-4 items-center justify-between bg-slate-50/50 dark:bg-slate-800/30">
          <div className="relative w-full md:w-96">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400" />
            <Input 
              placeholder="Search logs, usernames, or target IDs..." 
              className="pl-10 h-10 bg-white dark:bg-slate-900 border-slate-200 dark:border-slate-700 rounded-xl text-xs font-medium"
              value={searchTerm}
              onChange={e => setSearchTerm(e.target.value)}
            />
          </div>
          <div className="flex flex-wrap gap-2 w-full md:w-auto">
            <select 
              className="h-10 px-3 bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 rounded-xl text-xs font-bold text-slate-700 dark:text-slate-300 outline-none"
              value={categoryFilter}
              onChange={e => setCategoryFilter(e.target.value)}
            >
              <option value="ALL">All Categories</option>
              {categories.map(c => <option key={c} value={c}>{c}</option>)}
            </select>
            
            <select 
              className="h-10 px-3 bg-white dark:bg-slate-900 border border-slate-200 dark:border-slate-700 rounded-xl text-xs font-bold text-slate-700 dark:text-slate-300 outline-none"
              value={severityFilter}
              onChange={e => setSeverityFilter(e.target.value)}
            >
              <option value="ALL">All Severities</option>
              {severities.map(s => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
        </div>

        {/* Table */}
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table className="w-full text-xs text-left">
              <thead className="text-[10px] text-slate-400 uppercase font-black tracking-widest bg-white dark:bg-slate-900 border-b border-slate-100 dark:border-slate-800">
                <tr>
                  <th className="px-6 py-4">Timestamp</th>
                  <th className="px-6 py-4">Severity</th>
                  <th className="px-6 py-4">Category</th>
                  <th className="px-6 py-4">Action Details</th>
                  <th className="px-6 py-4">Target ID</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-50 dark:divide-slate-800/50">
                {filteredLogs.map(log => (
                  <tr key={log.id} className="hover:bg-slate-50/50 dark:hover:bg-slate-800/30 transition-colors group">
                    <td className="px-6 py-4 whitespace-nowrap">
                      <div className="flex items-center gap-2">
                        <Clock className="h-3.5 w-3.5 text-slate-400" />
                        <span className="font-mono text-slate-600 dark:text-slate-400">
                          {new Date(log.timestamp).toLocaleString(undefined, { 
                            month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' 
                          })}
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
                      {(log.username || log.userId) && (
                        <p className="text-[10px] font-bold text-slate-500 mt-1 uppercase tracking-widest flex items-center gap-1">
                          <User className="h-3 w-3" /> By {log.username || log.userId}
                        </p>
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
                ))}
                {filteredLogs.length === 0 && (
                  <tr>
                    <td colSpan={5} className="px-6 py-12 text-center">
                      <div className="flex flex-col items-center justify-center space-y-3">
                        <Search className="h-8 w-8 text-slate-300" />
                        <p className="text-slate-500 font-medium">No system logs match your filters.</p>
                      </div>
                    </td>
                  </tr>
                )}
              </tbody>
            </table>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
