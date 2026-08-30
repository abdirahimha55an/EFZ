export const storageCore = {
  get: (key: string): string | null => {
    if (typeof window === "undefined") return null;
    return localStorage.getItem(key);
  },

  set: (key: string, value: string): void => {
    if (typeof window === "undefined") return;
    try {
      localStorage.setItem(key, value);
    } catch (e: any) {
      console.error(`[STORAGE_CORE] Failed to write to localStorage for key: ${key}. Reason: ${e.message}`);
    }
  },

  remove: (key: string): void => {
    if (typeof window === "undefined") return;
    localStorage.removeItem(key);
  },

  clear: (): void => {
    if (typeof window === "undefined") return;
    localStorage.clear();
  },

  checkHealth: (): { ok: boolean; error?: string } => {
    if (typeof window === "undefined") return { ok: true };
    try {
      const testKey = "__efz_test__";
      localStorage.setItem(testKey, "1");
      localStorage.removeItem(testKey);
      return { ok: true };
    } catch (e: any) {
      if (e.name === 'QuotaExceededError' || e.name === 'NS_ERROR_DOM_QUOTA_REACHED') {
        return { ok: false, error: "Storage Quota Exceeded (5MB Limit Reached)" };
      }
      return { ok: false, error: "LocalStorage is disabled or unavailable" };
    }
  },

  getUsage: (keys: string[]): { used: string; count: number; percentage: string } => {
    if (typeof window === "undefined") return { used: "0 KB", count: 0, percentage: "0%" };
    let total = 0;
    for (const key of keys) {
      const val = localStorage.getItem(key);
      if (val) total += val.length * 2; // UTF-16 characters
    }
    const maxStorage = 5 * 1024 * 1024; // 5MB standard limit
    const percentage = Math.min((total / maxStorage) * 100, 100).toFixed(1) + "%";
    return { 
      used: total < 1024 ? `${total} B` : `${(total / 1024).toFixed(1)} KB`,
      count: keys.length,
      percentage
    };
  }
};
