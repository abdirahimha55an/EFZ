-- ============================================================================
-- EFZ Microsoft SQL Server Relational Schema
-- Target Database: football
-- ============================================================================

USE football;
GO

-- Disable all constraints to allow safe drop
EXEC sp_MSforeachtable "ALTER TABLE ? NOCHECK CONSTRAINT all";
GO

-- Drop tables in reverse dependency order if they exist
DROP TABLE IF EXISTS SystemIssues;
DROP TABLE IF EXISTS Backups;
DROP TABLE IF EXISTS Settings;
DROP TABLE IF EXISTS AuditLogs;
DROP TABLE IF EXISTS Payouts;
DROP TABLE IF EXISTS Commissions;
DROP TABLE IF EXISTS OrderItems;
DROP TABLE IF EXISTS Orders;
DROP TABLE IF EXISTS InventoryMovements;
DROP TABLE IF EXISTS Products;
DROP TABLE IF EXISTS Customers;
DROP TABLE IF EXISTS UserPermissions;
DROP TABLE IF EXISTS Users;
DROP TABLE IF EXISTS Permissions;
DROP TABLE IF EXISTS Roles;
GO

-- Re-enable constraints checks
EXEC sp_MSforeachtable "ALTER TABLE ? WITH CHECK CHECK CONSTRAINT all";
GO

-- ==========================================
-- 1. Roles & Permissions Tables
-- ==========================================

CREATE TABLE Roles (
    RoleName NVARCHAR(50) PRIMARY KEY,
    Description NVARCHAR(255) NULL,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Permissions (
    PermissionCode NVARCHAR(100) PRIMARY KEY, -- e.g., 'view_dashboard', 'create_orders'
    Description NVARCHAR(255) NULL,
    Category NVARCHAR(50) NOT NULL DEFAULT 'General'
);

-- ==========================================
-- 2. Users Table
-- ==========================================

CREATE TABLE Users (
    Id NVARCHAR(50) PRIMARY KEY,
    Name NVARCHAR(150) NOT NULL,
    Email NVARCHAR(150) NOT NULL UNIQUE,
    Phone NVARCHAR(50) NOT NULL,
    PasswordHash NVARCHAR(255) NOT NULL,
    Avatar NVARCHAR(MAX) NULL,
    RoleName NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Roles(RoleName),
    Status NVARCHAR(20) NOT NULL DEFAULT 'active' CHECK (Status IN ('active', 'inactive')),
    CommissionPercentage DECIMAL(5, 2) NOT NULL DEFAULT 5.00 CHECK (CommissionPercentage >= 0.00 AND CommissionPercentage <= 100.00),
    EarnedCommissionTotal DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (EarnedCommissionTotal >= 0.00),
    PendingCommissionTotal DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    PaidCommissionTotal DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (PaidCommissionTotal >= 0.00),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE UserPermissions (
    UserId NVARCHAR(50) FOREIGN KEY REFERENCES Users(Id) ON DELETE CASCADE,
    PermissionCode NVARCHAR(100) FOREIGN KEY REFERENCES Permissions(PermissionCode) ON DELETE CASCADE,
    PRIMARY KEY (UserId, PermissionCode)
);

-- ==========================================
-- 3. Customers Table
-- ==========================================

CREATE TABLE Customers (
    Id NVARCHAR(50) PRIMARY KEY,
    Name NVARCHAR(150) NOT NULL,
    Phone NVARCHAR(50) NOT NULL,
    RegisteredBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    MarketingOfficerId NVARCHAR(50) NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- ==========================================
-- 4. Products & Inventory Tables
-- ==========================================

CREATE TABLE Products (
    Id NVARCHAR(50) PRIMARY KEY,
    Name NVARCHAR(150) NOT NULL,
    Category NVARCHAR(100) NOT NULL,
    Price DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (Price >= 0.00), -- Legacy price alignment
    CostPrice DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (CostPrice >= 0.00),
    SellingPrice DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (SellingPrice >= 0.00),
    Stock INT NOT NULL DEFAULT 0 CHECK (Stock >= 0),
    LowStockThreshold INT NOT NULL DEFAULT 50 CHECK (LowStockThreshold >= 0),
    Size NVARCHAR(50) NULL,
    ImageUrl NVARCHAR(MAX) NULL,
    Description NVARCHAR(MAX) NULL,
    Durability NVARCHAR(50) NULL,
    SurfaceType NVARCHAR(100) NULL,
    IsWholesale BIT NOT NULL DEFAULT 1,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE InventoryMovements (
    Id NVARCHAR(50) PRIMARY KEY,
    ProductId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Products(Id) ON DELETE CASCADE,
    QuantityChange INT NOT NULL, -- Positive for stock increase, Negative for deduction
    Reason NVARCHAR(255) NOT NULL, -- 'Order Created', 'Manual Adjustment', 'Storage Repair'
    CreatedBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- ==========================================
-- 5. Orders & Financial Tables
-- ==========================================

CREATE TABLE Orders (
    Id NVARCHAR(50) PRIMARY KEY,
    CustomerId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Customers(Id),
    MarketingOfficerId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    Total DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (Total >= 0.00),
    Cost DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (Cost >= 0.00),
    GrossProfit DECIMAL(18, 2) NOT NULL DEFAULT 0.00,
    Status NVARCHAR(50) NOT NULL DEFAULT 'pending' CHECK (Status IN ('pending', 'paid', 'delivered', 'cancelled', 'successfully delivered', 'completed')),
    PaymentStatus NVARCHAR(50) NOT NULL DEFAULT 'unpaid' CHECK (PaymentStatus IN ('paid', 'unpaid')),
    CommissionPaid BIT NOT NULL DEFAULT 0,
    Date DATE NOT NULL DEFAULT CAST(SYSUTCDATETIME() AS DATE),
    DeliveryNotes NVARCHAR(MAX) NULL,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE OrderItems (
    OrderId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Orders(Id) ON DELETE CASCADE,
    ProductId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Products(Id),
    Quantity INT NOT NULL CHECK (Quantity > 0),
    Price DECIMAL(18, 2) NOT NULL CHECK (Price >= 0.00),
    PRIMARY KEY (OrderId, ProductId)
);

CREATE TABLE Commissions (
    OrderId NVARCHAR(50) PRIMARY KEY FOREIGN KEY REFERENCES Orders(Id) ON DELETE CASCADE,
    UserId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    CommissionPercentage DECIMAL(5, 2) NOT NULL,
    CommissionAmount DECIMAL(18, 2) NOT NULL CHECK (CommissionAmount >= 0.00),
    Status NVARCHAR(20) NOT NULL DEFAULT 'pending' CHECK (Status IN ('pending', 'paid')),
    PayoutId NVARCHAR(50) NULL, -- Linked later when paid out
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Payouts (
    Id NVARCHAR(50) PRIMARY KEY,
    UserId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    Amount DECIMAL(18, 2) NOT NULL CHECK (Amount > 0.00),
    PaidBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- Establish Commissions to Payouts FK relation
ALTER TABLE Commissions ADD CONSTRAINT FK_Commissions_Payouts FOREIGN KEY (PayoutId) REFERENCES Payouts(Id);

-- ==========================================
-- 6. Infrastructure & Diagnostics Tables
-- ==========================================

CREATE TABLE AuditLogs (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Category NVARCHAR(50) NOT NULL, -- 'SYSTEM', 'FINANCIAL', 'CRM', 'INVENTORY', 'SECURITY', 'AUTH'
    Severity NVARCHAR(20) NOT NULL, -- 'INFO', 'WARNING', 'ERROR', 'CRITICAL'
    Message NVARCHAR(MAX) NOT NULL,
    UserId NVARCHAR(50) NULL FOREIGN KEY REFERENCES Users(Id) ON DELETE SET NULL,
    TargetId NVARCHAR(100) NULL,
    Metadata NVARCHAR(MAX) NULL, -- JSON string representation
    Timestamp DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE SystemIssues (
    Id NVARCHAR(100) PRIMARY KEY, -- e.g., 'inv-neg', 'dup-users', or generated uuid
    Title NVARCHAR(255) NOT NULL,
    Severity NVARCHAR(20) NOT NULL CHECK (Severity IN ('INFO', 'WARNING', 'ERROR', 'CRITICAL')),
    Source NVARCHAR(100) NOT NULL,
    AffectedEntityType NVARCHAR(50) NOT NULL,
    AffectedEntityId NVARCHAR(100) NULL,
    AffectedCount INT NOT NULL DEFAULT 1,
    Explanation NVARCHAR(MAX) NOT NULL,
    RecommendedAction NVARCHAR(MAX) NULL,
    Repairable BIT NOT NULL DEFAULT 0,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    LastDetectedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Backups (
    Id NVARCHAR(50) PRIMARY KEY,
    BackupPath NVARCHAR(MAX) NOT NULL,
    CreatedBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    FileSizeB BIGINT NOT NULL DEFAULT 0,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Settings (
    SettingKey NVARCHAR(100) PRIMARY KEY,
    SettingValue NVARCHAR(MAX) NULL,
    Description NVARCHAR(255) NULL,
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

-- ==========================================
-- 7. High-Performance Indexes
-- ==========================================

CREATE INDEX IX_Users_RoleName ON Users(RoleName);
CREATE INDEX IX_Customers_RegisteredBy ON Customers(RegisteredBy);
CREATE INDEX IX_Customers_MarketingOfficerId ON Customers(MarketingOfficerId);
CREATE INDEX IX_Products_Category ON Products(Category);
CREATE INDEX IX_Orders_CustomerId ON Orders(CustomerId);
CREATE INDEX IX_Orders_MarketingOfficerId ON Orders(MarketingOfficerId);
CREATE INDEX IX_Orders_Status ON Orders(Status);
CREATE INDEX IX_OrderItems_ProductId ON OrderItems(ProductId);
CREATE INDEX IX_Commissions_UserId ON Commissions(UserId);
CREATE INDEX IX_Commissions_Status ON Commissions(Status);
CREATE INDEX IX_Payouts_UserId ON Payouts(UserId);
CREATE INDEX IX_AuditLogs_Category ON AuditLogs(Category);
CREATE INDEX IX_AuditLogs_Timestamp ON AuditLogs(Timestamp DESC);
CREATE INDEX IX_SystemIssues_Severity ON SystemIssues(Severity);
GO
