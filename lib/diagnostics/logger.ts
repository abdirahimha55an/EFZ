import { storageCore } from "../storage/core";
import { LOGS_KEY } from "../storage/keys";
import { SystemLog, LogSeverity, LogCategory } from "../types";

export const loggerService = {
  log: (category: LogCategory, severity: LogSeverity, message: string, data?: { userId?: string, targetId?: string, metadata?: any }) => {
    const logs = loggerService.getLogs();
    
    // Fallback for generating an ID without window.crypto
    const generateId = () => `log-${Date.now()}-${Math.random().toString(36).substring(2, 9)}`;

    const newLog: SystemLog = {
      id: generateId(),
      timestamp: new Date().toISOString(),
      category,
      severity,
      message,
      userId: data?.userId,
      targetId: data?.targetId,
      metadata: data?.metadata
    };
    
    // Prepend new log
    const updated = [newLog, ...logs].slice(0, 1000); // Keep last 1000 logs
    storageCore.set(LOGS_KEY, JSON.stringify(updated));
    console.log(`[${category}][${severity}] ${message}`);
  },

  getLogs: (): SystemLog[] => {
    const stored = storageCore.get(LOGS_KEY);
    if (!stored) return [];
    try {
      return JSON.parse(stored);
    } catch {
      return [];
    }
  },

  clearLogs: () => {
    storageCore.remove(LOGS_KEY);
  }
};
