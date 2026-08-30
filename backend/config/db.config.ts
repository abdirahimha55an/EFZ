export const dbConfig = {
  server: process.env.DB_SERVER || "localhost",
  database: process.env.DB_NAME || "football",
  user: process.env.DB_USER || "sa",
  password: process.env.DB_PASSWORD || "YourStrongPassword123!",
  port: parseInt(process.env.DB_PORT || "1433", 10),
  options: {
    encrypt: process.env.DB_ENCRYPT === "true", // Use true for Azure SQL
    trustServerCertificate: true, // true for local development
    enableArithAbort: true,
    connectTimeout: 15000,
    requestTimeout: 30000,
  },
  pool: {
    max: 10,
    min: 0,
    idleTimeoutMillis: 30000
  }
};
