"use client";

import { Suspense, useState, useEffect } from "react";
import { useRouter, useSearchParams } from "next/navigation";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent } from "@/components/ui/card";
import { ShieldCheck, Eye, EyeOff, Loader2 } from "lucide-react";

import { getDb, describeDbError } from "@/lib/supabase/db";

/**
 * useSearchParams() opts a route out of static prerendering unless it sits
 * inside a Suspense boundary, so the form lives in its own component.
 */
export default function AdminLogin() {
  return (
    <Suspense
      fallback={
        <div className="min-h-screen flex items-center justify-center bg-slate-50">
          <Loader2 className="h-6 w-6 animate-spin text-brand-blue" />
        </div>
      }
    >
      <AdminLoginForm />
    </Suspense>
  );
}

function AdminLoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [showPassword, setShowPassword] = useState(false);
  const [error, setError] = useState("");
  const [isLoading, setIsLoading] = useState(false);
  const [settings, setSettings] = useState({
    businessName: "Elite Football Zone",
    logo: ""
  });

  useEffect(() => {
    let cancelled = false;

    (async () => {
      try {
        const db = getDb();

        // Branding is readable without a session - settings is one of the two
        // tables the public site is allowed to select from.
        const [nextSettings, authUser] = await Promise.all([
          db.settings.get(),
          db.auth.getAuthUser(),
        ]);
        if (cancelled) return;

        setSettings({ businessName: nextSettings.businessName, logo: nextSettings.logo });
        if (authUser) router.replace("/admin");
      } catch {
        // A missing or misconfigured Supabase project should still leave a
        // usable form on screen; the sign-in attempt will report the real error.
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [router]);

  const handleLogin = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);
    setError("");

    try {
      const db = getDb();
      await db.auth.login(email, password);

      // Authenticating proves who they are. It does not prove they are staff:
      // an auth user with no linked profile, or a suspended one, gets nothing.
      const profile = await db.auth.getProfile();

      if (!profile) {
        await db.auth.logout();
        setError("This account is not linked to a staff profile. Contact your Super Admin.");
        setIsLoading(false);
        return;
      }

      if (profile.status === "inactive") {
        await db.auth.logout();
        setError("Your account has been suspended. Contact Super Admin.");
        setIsLoading(false);
        return;
      }

      await db.logs.write({
        category: "SECURITY",
        severity: "INFO",
        message: `User login successful: ${profile.name} (${profile.role})`,
        targetId: profile.id,
      });

      // refresh() lets proxy.ts see the new session cookie before /admin renders.
      const next = searchParams.get("next");
      router.replace(next && next.startsWith("/admin") ? next : "/admin");
      router.refresh();
    } catch (error) {
      // A failed attempt cannot write to system_logs - the caller is not
      // authenticated, and the insert policy is authenticated-only. Supabase
      // Auth records failed sign-ins in its own logs instead.
      setError(describeDbError(error));
      setIsLoading(false);
    }
  };

  return (
    <div className="min-h-screen flex items-center justify-center bg-slate-50 p-4">
      <Card className="w-full max-w-md shadow-xl border-none">
        <div className="bg-brand-blue-dark rounded-t-xl p-8 text-center text-white">
          <div className="inline-flex h-20 w-20 items-center justify-center rounded-2xl bg-white/10 mb-4 overflow-hidden p-2">
            {settings.logo ? (
              <img src={settings.logo} alt={settings.businessName} className="h-full w-full object-contain" />
            ) : (
              <ShieldCheck className="h-10 w-10 text-brand-green" />
            )}
          </div>
          <h1 className="font-heading text-2xl font-bold">
            {settings.businessName}
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

            {/* "Remember Session" is gone: Supabase persists the session in a
                cookie and rotates it on every request, so the choice no longer
                exists to offer. */}
            <div className="flex items-center justify-end px-1">
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
