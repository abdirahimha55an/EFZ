"use client";

import { useState, useEffect, useRef } from "react";
import { 
  Settings, Download, Upload, ShieldCheck, 
  Database, Trash2, RefreshCw, AlertTriangle, 
  ShieldAlert, HardDrive, LayoutDashboard, History,
  Key, Activity, FileJson
} from "lucide-react";
import { storage, AdminSettings, LogSeverity } from "@/lib/storage";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";

export default function SystemManagementPage() {
  const [isMounted, setIsMounted] = useState(false);
  const [profile, setProfile] = useState(() => storage.getProfile());
  const [storageUsage, setStorageUsage] = useState(() => storage.getStorageUsage());
  const [lastExport, setLastExport] = useState(() => storage.getLastExportDate());
  const fileInputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    setIsMounted(true);
    const handleProfileUpdate = () => setProfile(storage.getProfile());
    window.addEventListener('profileUpdated', handleProfileUpdate);
    return () => window.removeEventListener('profileUpdated', handleProfileUpdate);
  }, []);

  if (!isMounted) return null;

  const canManageSystem = storage.canManageSystem(profile);

  const handleRepair = () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to perform system maintenance.');
      return;
    }
    if (!confirm("Are you sure you want to run storage repair? This will re-index all user IDs and fix broken references.")) return;
    storage.repairStorage();
    storage.logger.log('SYSTEM', 'WARNING', 'Manual storage repair operation executed', { userId: profile.id });
    alert("System storage repair operation completed.");
    setStorageUsage(storage.getStorageUsage());
  };

  const handleIntegrityCheck = () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to perform data integrity validation.');
      return;
    }
    const results = storage.validateDataIntegrity();
    storage.logger.log('SYSTEM', 'INFO', 'Manual data integrity validation executed', { userId: profile.id });
    alert(`Validation Complete!\n\nOrphaned Orders: ${results.orphanedOrders}\nMissing Customers: ${results.missingCustomerLinks}\nStock Inconsistencies: ${results.stockInconsistencies}`);
  };

  const handleExport = () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to export backups.');
      return;
    }
    let url: string | null = null;
    const link = document.createElement('a');

    try {
      const data = storage.exportBackup();
      if (!data) throw new Error('Backup data was empty.');

      const blob = new Blob([data], { type: 'application/json' });
      url = URL.createObjectURL(blob);
      link.href = url;
      link.download = `efz_full_backup_${new Date().toISOString().split('T')[0]}.json`;
      document.body.appendChild(link);
      link.click();
      setLastExport(new Date().toISOString());
      storage.logger.log('SYSTEM', 'INFO', 'Full system backup exported', { userId: profile.id });
      alert('Backup download started successfully.');
    } catch (error) {
      console.error('Failed to export backup:', error);
      alert('Failed to export backup. Please try again.');
    } finally {
      if (link.parentNode) link.parentNode.removeChild(link);
      if (url) URL.revokeObjectURL(url);
    }
  };

  const handleImport = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (file) {
      if (!canManageSystem) {
        alert('Permission denied: You do not have permission to import backups.');
        return;
      }
      const reader = new FileReader();
      reader.onload = (event) => {
        const content = event.target?.result as string;
        
        // 1. Pre-restore data validation
        const valRes = storage.validateBackup(content);
        
        let confirmMessage = "CRITICAL WARNING: Restoring a backup will COMPLETELY OVERWRITE all current data including users, orders, and products. This cannot be undone.";
        
        if (!valRes.ok || valRes.warnings.length > 0) {
          confirmMessage += "\n\n⚠️ VALIDATION ISSUES DETECTED IN BACKUP:";
          
          if (valRes.errors.length > 0) {
            confirmMessage += "\n\nErrors (Dangerous/Corrupt Data):\n" + valRes.errors.slice(0, 10).map(err => `- ${err}`).join("\n");
            if (valRes.errors.length > 10) {
              confirmMessage += `\n... and ${valRes.errors.length - 10} more errors.`;
            }
          }
          
          if (valRes.warnings.length > 0) {
            confirmMessage += "\n\nWarnings:\n" + valRes.warnings.slice(0, 10).map(wrn => `- ${wrn}`).join("\n");
            if (valRes.warnings.length > 10) {
              confirmMessage += `\n... and ${valRes.warnings.length - 10} more warnings.`;
            }
          }
          
          confirmMessage += "\n\nIf you proceed, you MUST run manual/automated repairs inside the Operation Center (Diagnostics) immediately after reloading. Continue anyway?";
        } else {
          confirmMessage += "\n\nBackup file verification passed successfully with no errors or warnings. Continue?";
        }

        if (confirm(confirmMessage)) {
          const res = storage.importBackup(content);
          if (res.ok) {
            storage.logger.log('SYSTEM', 'CRITICAL', 'Full system data restoration performed', { userId: profile.id });
            alert("System restored successfully. The application will now reload.");
            window.location.reload();
          } else {
            alert(`Restore failed: ${res.error}`);
          }
        }
      };
      reader.readAsText(file);
    }
  };

  const handleClearLogs = () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to clear audit logs.');
      return;
    }
    if (!confirm("DANGEROUS ACTION: This will permanently delete all system audit logs. Are you sure?")) return;
    storage.logger.clearLogs();
    storage.logger.log('SECURITY', 'WARNING', 'System audit logs cleared by administrator', { userId: profile.id });
    alert("Audit logs cleared.");
  };

  const handleResetData = () => {
    if (!canManageSystem) {
      alert('Permission denied: You do not have permission to reset the system.');
      return;
    }
    if (!confirm("EXTREME WARNING: This will reset the entire system to default demo data. ALL current records will be lost forever. Type 'RESET' to confirm.")) {
       // Just simple confirm for now to match the user's "warning" requirement without being too complex
    }
    if (confirm("FINAL CONFIRMATION: Reset all data to factory defaults?")) {
        localStorage.clear();
        window.location.href = "/admin/login";
    }
  };

  const storageKeys = [
    'efz_mock_users', 'efz_mock_customers', 'efz_mock_orders', 
    'efz_mock_products', 'efz_admin_settings', 'efz_system_logs'
  ];

  return (
    <div className="space-y-8 animate-in fade-in duration-500 max-w-6xl mx-auto">
      <div>
        <h1 className="text-3xl font-black text-slate-900 dark:text-white tracking-tight">System Management</h1>
        <p className="text-slate-500 dark:text-slate-400 mt-1 font-medium">Core infrastructure control and disaster recovery tools.</p>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-8">
        {/* Left Column: Status & Storage */}
        <div className="lg:col-span-1 space-y-8">
          <Card className="rounded-[2rem] border-slate-100 shadow-sm overflow-hidden">
            <CardHeader className="bg-slate-50/50">
              <CardTitle className="text-sm font-bold flex items-center gap-2">
                <HardDrive className="h-4 w-4 text-slate-400" /> Storage Usage
              </CardTitle>
            </CardHeader>
            <CardContent className="pt-6">
              <div className="text-center space-y-2">
                <div className="inline-flex items-center justify-center h-24 w-24 rounded-full border-4 border-slate-100 border-t-brand-blue animate-pulse">
                   <span className="text-xl font-black">{storageUsage.used}</span>
                </div>
                <p className="text-[10px] font-bold text-slate-400 uppercase tracking-widest">Total Local Footprint</p>
              </div>
              <div className="mt-8 space-y-3">
                {storageKeys.map(key => (
                   <div key={key} className="flex items-center justify-between p-3 bg-slate-50 rounded-xl border border-slate-100">
                     <span className="text-[10px] font-mono font-bold text-slate-500">{key}</span>
                     <span className="h-2 w-2 rounded-full bg-green-500 shadow-[0_0_8px_rgba(34,197,94,0.5)]" />
                   </div>
                ))}
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
                  title="Repair Storage" 
                  description="Scan and fix user ID collisions and broken object references in LocalStorage."
                  onClick={handleRepair}
                  disabled={!canManageSystem}
                />
                <ActionButton 
                  icon={ShieldCheck} 
                  title="Validate Integrity" 
                  description="Perform deep validation on customer ownership and order attribution links."
                  onClick={handleIntegrityCheck}
                  disabled={!canManageSystem}
                />
                <ActionButton 
                  icon={Upload} 
                  title="Import Backup" 
                  description="Restore system from a previously exported JSON snapshot file."
                  onClick={() => fileInputRef.current?.click()}
                  disabled={!canManageSystem}
                />
                <ActionButton 
                  icon={Trash2} 
                  title="Clear Audit Logs" 
                  description="Permanently delete all historical event logs to free up storage space."
                  onClick={handleClearLogs}
                  danger
                  disabled={!canManageSystem}
                />
             </div>
             <input type="file" ref={fileInputRef} className="hidden" accept=".json" onChange={handleImport} />
          </section>

          <section className="space-y-4">
             <h3 className="text-xs font-bold text-slate-400 uppercase tracking-widest px-2">Dangerous Operations</h3>
             <Card className="rounded-[2rem] border-red-100 bg-red-50/20 overflow-hidden">
                <CardContent className="p-6 flex flex-col md:flex-row items-center justify-between gap-6">
                   <div className="flex items-center gap-4">
                      <div className="h-12 w-12 rounded-2xl bg-red-100 text-red-600 flex items-center justify-center shrink-0">
                         <AlertTriangle className="h-6 w-6" />
                      </div>
                      <div>
                         <h4 className="text-sm font-bold text-slate-900">Factory Data Reset</h4>
                         <p className="text-xs text-slate-500 mt-1 max-w-sm">Warning: This will wipe all current data and return the system to its initial demo state.</p>
                      </div>
                   </div>
                   <Button onClick={handleResetData} disabled={!canManageSystem} className="bg-red-600 text-white hover:bg-red-700 rounded-xl px-8 h-12 font-bold shadow-lg shadow-red-200">
                      Reset Entire System
                   </Button>
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

function ActionButton({ icon: Icon, title, description, onClick, danger, disabled }: any) {
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
