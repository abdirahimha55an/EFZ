"use client";

import { useState, useEffect } from "react";
import { useRouter } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { Lock, ShieldCheck, Eye, EyeOff, Loader2 } from "lucide-react";

import { storage } from "@/lib/storage";

export default function AdminLogin() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [rememberMe, setRememberMe] = useState(true);
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [isMounted, setIsMounted] = useState(false);
  const [settings, setSettings] = useState({
    businessName: "Elite Football Zone",
    logo: ""
  });

  useEffect(() => {
    setIsMounted(true);
    setSettings(storage.getSettings());
    
    // Redirect if already logged in
    if (storage.isLoggedIn()) {
      router.push("/admin");
    }
  }, [router]);

  const handleLogin = (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    setError("");

    // Simple mock auth with storage session
    const users = storage.getUsers();
    const user = users.find(u => u.email === email && (u.password || "admin123") === password);

    if (user) {
      if (user.status === 'inactive') {
        setError("Your account has been suspended. Contact Super Admin.");
        setIsLoading(false);
        return;
      }
      
      // Handle Remember Me vs Session Only
      console.log(`[AUTH] Initiating session for: ${user.name} (${user.id})`);
      storage.login(user.id); 
      storage.logger.log('SECURITY', 'INFO', `User login successful: ${user.name} (${user.role})`);
      router.push("/admin");
    } else {
      storage.logger.log('SECURITY', 'WARNING', `Failed login attempt for: ${email}`);
      setError("Authentication failed. Please check your credentials.");
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50 p-4">
      <Card className="w-full max-w-md shadow-xl border-none">
        <div className="bg-brand-blue-dark rounded-t-xl p-8 text-center text-white">
          <div className="inline-flex h-20 w-20 items-center justify-center rounded-2xl bg-white/10 mb-4 overflow-hidden p-2">
            {!isMounted ? (
              <Lock className="h-8 w-8 text-brand-green" />
            ) : settings.logo ? (
              <img src={settings.logo} alt={settings.businessName} className="h-full w-full object-contain" />
            ) : (
              <ShieldCheck className="h-10 w-10 text-brand-green" />
            )}
          </div>
          <h1 className="font-heading text-2xl font-bold">
            {!isMounted ? "Admin Access" : settings.businessName}
          </h1>
          <p className="text-slate-300 text-sm mt-2">Sign in to manage your platform</p>
        </div>
        <CardContent className="p-8">
          <form onSubmit={handleLogin} className="space-y-6">
            {error && (
              <div className="p-3 rounded bg-red-50 text-red-600 text-sm font-medium border border-red-100">
                {error}
              </div>
            )}
            <div className="space-y-2">
              <label className="text-sm font-bold text-slate-700 ml-1">Work Email</label>
              <Input 
                type="email" 
                required 
                placeholder="admin@efz.so"
                className="h-12 rounded-xl bg-slate-50 border-slate-200 focus:bg-white transition-all"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
              />
            </div>
            <div className="space-y-2">
              <label className="text-sm font-bold text-slate-700 ml-1">Security Password</label>
              <div className="relative">
                <Input 
                  type={showPassword ? "text" : "password"} 
                  required 
                  placeholder="••••••••"
                  className="h-12 rounded-xl bg-slate-50 border-slate-200 pr-12 focus:bg-white transition-all"
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                />
                <button
                  type="button"
                  onClick={() => setShowPassword(!showPassword)}
                  className="absolute right-3 top-1/2 -translate-y-1/2 p-2 text-slate-400 hover:text-slate-600 transition-colors"
                >
                  {showPassword ? <EyeOff className="h-4 w-4" /> : <Eye className="h-4 w-4" />}
                </button>
              </div>
            </div>

            <div className="flex items-center justify-between px-1">
              <label className="flex items-center gap-2 cursor-pointer group">
                <input 
                  type="checkbox" 
                  checked={rememberMe}
                  onChange={(e) => setRememberMe(e.target.checked)}
                  className="h-4 w-4 rounded border-slate-300 text-brand-blue focus:ring-brand-blue/20"
                />
                <span className="text-xs font-bold text-slate-500 group-hover:text-slate-700 transition-colors">Remember Session</span>
              </label>
              <button type="button" className="text-xs font-bold text-brand-blue hover:underline">Forgot Access?</button>
            </div>

            <Button type="submit" className="w-full h-14 bg-slate-900 text-white rounded-2xl font-bold text-lg shadow-xl shadow-slate-200 hover:bg-slate-800 transition-all flex items-center justify-center gap-2" disabled={isLoading}>
              {isLoading ? (
                <>
                  <Loader2 className="h-5 w-5 animate-spin" />
                  Verifying Identity...
                </>
              ) : "Unlock Dashboard"}
            </Button>
          </form>
        </CardContent>
      </Card>
    </div>
  );
}
