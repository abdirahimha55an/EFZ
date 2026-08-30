import { storageCore } from "../storage/core";
import { SETTINGS_KEY, NOTIFICATIONS_KEY } from "../storage/keys";
import { AdminSettings, Notification } from "../types";

export const settingsService = {
  getSettings: (): AdminSettings => {
    const defaults: AdminSettings = {
      businessName: "Elite Football Zone",
      shortName: "EFZ",
      logo: "",
      favicon: "",
      whatsappNumber: "+252 61 412 9991",
      contactEmail: "sales@efz.so",
      defaultLowStockThreshold: 50,
      currencySymbol: "$",
      theme: 'light',
      primaryColor: "#0F172A",
      secondaryColor: "#00E676"
    };
    const stored = storageCore.get(SETTINGS_KEY);
    return stored ? JSON.parse(stored) : defaults;
  },

  saveSettings: (settings: AdminSettings) => {
    storageCore.set(SETTINGS_KEY, JSON.stringify(settings));
  },

  getTheme: (): 'light' | 'dark' => {
    const settings = settingsService.getSettings();
    return settings.theme || 'light';
  },

  setTheme: (theme: 'light' | 'dark') => {
    const settings = settingsService.getSettings();
    settingsService.saveSettings({ ...settings, theme });
  },

  getNotifications: (): Notification[] => {
    const stored = storageCore.get(NOTIFICATIONS_KEY);
    return stored ? JSON.parse(stored) : [];
  },

  saveNotifications: (notifications: Notification[]) => {
    storageCore.set(NOTIFICATIONS_KEY, JSON.stringify(notifications));
  }
};
