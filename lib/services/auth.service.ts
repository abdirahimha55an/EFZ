import { storageCore } from "../storage/core";
import { SESSION_KEY } from "../storage/keys";
import { AdminProfile } from "../types";
import { userService } from "./user.service";
import { loggerService } from "../diagnostics/logger";

export const authService = {
  getProfile: (): AdminProfile => {
    const users = userService.getUsers();
    const guestProfile: AdminProfile = {
      ...(users[0] || {}),
      id: "guest",
      name: "Guest",
      email: "",
      role: 'Marketing Officer',
      status: 'active',
      avatar: "",
      phone: "",
      commissionPercentage: 0,
      earnedCommissionTotal: 0,
      pendingCommissionTotal: 0,
      paidCommissionTotal: 0,
      permissions: []
    };

    if (typeof window === "undefined") return guestProfile;
    
    const sessionUserId = storageCore.get(SESSION_KEY);
    if (!sessionUserId) return guestProfile;
    
    const user = users.find(u => String(u.id) === String(sessionUserId));
    if (user) {
      return user;
    }
    
    loggerService.log('AUTH', 'WARNING', `Session user ID ${sessionUserId} not found. Clearing session.`);
    authService.logout();
    return guestProfile;
  },

  saveProfile: (profile: AdminProfile) => {
    const users = userService.getUsers();
    const updated = users.map(u => u.id === profile.id ? profile : u);
    userService.saveUsers(updated);
  },

  login: (userId: string) => {
    authService.logout(); 
    storageCore.set(SESSION_KEY, userId);
  },

  logout: () => {
    storageCore.remove(SESSION_KEY);
    storageCore.remove("efz_mock_profile");
    storageCore.remove("efz_current_user");
    storageCore.remove("efz_admin_session_email");
  },

  isLoggedIn: (): boolean => {
    return !!storageCore.get(SESSION_KEY);
  }
};
