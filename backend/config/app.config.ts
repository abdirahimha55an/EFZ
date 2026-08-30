export const appConfig = {
  port: parseInt(process.env.PORT || "3001", 10),
  env: process.env.NODE_ENV || "development",
  jwtSecret: process.env.JWT_SECRET || "efz_super_secure_operational_intelligence_key_2026",
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || "8h",
  saltRounds: 10,
  backupSchedule: process.env.BACKUP_SCHEDULE || "0 0 * * *", // Daily at midnight
  maxBackupAgeDays: 30
};
