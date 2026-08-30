-- ============================================================================
-- EFZ Microsoft SQL Server Master Schema
-- Target Database: football
-- Author: Antigravity AI Code Assistant
-- ============================================================================

/*
  INSTRUCTIONS:
  1. Open SQL Server Management Studio (SSMS) or Azure Data Studio.
  2. Connect to your SQL Server instance.
  3. Ensure a database named 'football' exists, or run:
     CREATE DATABASE football;
  4. Open this file and execute the entire script.
*/

CREATE DATABASE football;
GO

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

-- ============================================================================
-- PART 1: RELATIONAL TABLES SCHEMA
-- ============================================================================

CREATE TABLE Roles (
    RoleName NVARCHAR(50) PRIMARY KEY,
    Description NVARCHAR(255) NULL,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Permissions (
    PermissionCode NVARCHAR(100) PRIMARY KEY,
    Description NVARCHAR(255) NULL,
    Category NVARCHAR(50) NOT NULL DEFAULT 'General'
);

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

CREATE TABLE Customers (
    Id NVARCHAR(50) PRIMARY KEY,
    Name NVARCHAR(150) NOT NULL,
    Phone NVARCHAR(50) NOT NULL,
    RegisteredBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    MarketingOfficerId NVARCHAR(50) NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME(),
    UpdatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Products (
    Id NVARCHAR(50) PRIMARY KEY,
    Name NVARCHAR(150) NOT NULL,
    Category NVARCHAR(100) NOT NULL,
    Price DECIMAL(18, 2) NOT NULL DEFAULT 0.00 CHECK (Price >= 0.00),
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
    QuantityChange INT NOT NULL,
    Reason NVARCHAR(255) NOT NULL,
    CreatedBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

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
    PayoutId NVARCHAR(50) NULL,
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE Payouts (
    Id NVARCHAR(50) PRIMARY KEY,
    UserId NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    Amount DECIMAL(18, 2) NOT NULL CHECK (Amount > 0.00),
    PaidBy NVARCHAR(50) NOT NULL FOREIGN KEY REFERENCES Users(Id),
    CreatedAt DATETIME2 DEFAULT SYSUTCDATETIME()
);

ALTER TABLE Commissions ADD CONSTRAINT FK_Commissions_Payouts FOREIGN KEY (PayoutId) REFERENCES Payouts(Id);

CREATE TABLE AuditLogs (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Category NVARCHAR(50) NOT NULL,
    Severity NVARCHAR(20) NOT NULL,
    Message NVARCHAR(MAX) NOT NULL,
    UserId NVARCHAR(50) NULL FOREIGN KEY REFERENCES Users(Id) ON DELETE SET NULL,
    TargetId NVARCHAR(100) NULL,
    Metadata NVARCHAR(MAX) NULL,
    Timestamp DATETIME2 DEFAULT SYSUTCDATETIME()
);

CREATE TABLE SystemIssues (
    Id NVARCHAR(100) PRIMARY KEY,
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

-- Performance Indexes
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

-- ============================================================================
-- PART 2: BUSINESS LOGIC FUNCTIONS
-- ============================================================================

DROP FUNCTION IF EXISTS dbo.fn_CalculateProductProfit;
GO
CREATE FUNCTION dbo.fn_CalculateProductProfit (
    @ProductId NVARCHAR(50)
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @Profit DECIMAL(18, 2) = 0.00;
    SELECT @Profit = (SellingPrice - CostPrice) FROM Products WHERE Id = @ProductId;
    RETURN ISNULL(@Profit, 0.00);
END;
GO

DROP FUNCTION IF EXISTS dbo.fn_CalculateOrderGrossProfit;
GO
CREATE FUNCTION dbo.fn_CalculateOrderGrossProfit (
    @OrderId NVARCHAR(50)
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @GrossProfit DECIMAL(18, 2) = 0.00;
    SELECT @GrossProfit = SUM((oi.Price - p.CostPrice) * oi.Quantity)
    FROM OrderItems oi JOIN Products p ON oi.ProductId = p.Id WHERE oi.OrderId = @OrderId;
    RETURN ISNULL(@GrossProfit, 0.00);
END;
GO

DROP FUNCTION IF EXISTS dbo.fn_CalculateCommissionAmount;
GO
CREATE FUNCTION dbo.fn_CalculateCommissionAmount (
    @OrderTotal DECIMAL(18, 2),
    @CommissionPercentage DECIMAL(5, 2)
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    RETURN ISNULL((@OrderTotal * @CommissionPercentage) / 100.00, 0.00);
END;
GO

DROP FUNCTION IF EXISTS dbo.fn_CheckStockAvailability;
GO
CREATE FUNCTION dbo.fn_CheckStockAvailability (
    @ProductId NVARCHAR(50),
    @RequestedQuantity INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @IsAvailable BIT = 0;
    DECLARE @CurrentStock INT = 0;
    SELECT @CurrentStock = Stock FROM Products WHERE Id = @ProductId;
    IF @CurrentStock >= @RequestedQuantity AND @RequestedQuantity > 0 SET @IsAvailable = 1;
    RETURN @IsAvailable;
END;
GO

DROP FUNCTION IF EXISTS dbo.fn_CalculateInventoryValue;
GO
CREATE FUNCTION dbo.fn_CalculateInventoryValue (
    @CategoryFilter NVARCHAR(100) = NULL
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @TotalValue DECIMAL(18, 2) = 0.00;
    SELECT @TotalValue = SUM(Stock * CostPrice) FROM Products WHERE (@CategoryFilter IS NULL OR Category = @CategoryFilter);
    RETURN ISNULL(@TotalValue, 0.00);
END;
GO

-- ============================================================================
-- PART 3: AGGREGATION VIEWS
-- ============================================================================

DROP VIEW IF EXISTS uv_SystemHealthSummary;
DROP VIEW IF EXISTS uv_AuditLogSummary;
DROP VIEW IF EXISTS uv_PayoutSummary;
DROP VIEW IF EXISTS uv_CommissionSummary;
DROP VIEW IF EXISTS uv_OrderSummary;
DROP VIEW IF EXISTS uv_InventorySummary;
DROP VIEW IF EXISTS uv_CustomerOwnershipSummary;
DROP VIEW IF EXISTS uv_UserPermissionSummary;
GO

CREATE VIEW uv_UserPermissionSummary
AS
SELECT 
    u.Id AS UserId, u.Name AS UserName, u.Email, u.Phone, u.RoleName, u.Status, u.CommissionPercentage, u.EarnedCommissionTotal, u.PendingCommissionTotal, u.PaidCommissionTotal,
    STRING_AGG(up.PermissionCode, ',') WITHIN GROUP (ORDER BY up.PermissionCode) AS PermissionsList, u.CreatedAt
FROM Users u LEFT JOIN UserPermissions up ON u.Id = up.UserId
GROUP BY u.Id, u.Name, u.Email, u.Phone, u.RoleName, u.Status, u.CommissionPercentage, u.EarnedCommissionTotal, u.PendingCommissionTotal, u.PaidCommissionTotal, u.CreatedAt;
GO

CREATE VIEW uv_CustomerOwnershipSummary
AS
SELECT c.Id AS CustomerId, c.Name AS CustomerName, c.Phone AS CustomerPhone, c.RegisteredBy AS CreatorId, uCreator.Name AS CreatorName, c.MarketingOfficerId AS OfficerId, uOfficer.Name AS OfficerName, c.CreatedAt
FROM Customers c JOIN Users uCreator ON c.RegisteredBy = uCreator.Id LEFT JOIN Users uOfficer ON c.MarketingOfficerId = uOfficer.Id;
GO

CREATE VIEW uv_InventorySummary
AS
SELECT p.Id AS ProductId, p.Name AS ProductName, p.Category, p.Price, p.CostPrice, p.SellingPrice, p.Stock, p.LowStockThreshold, p.Size, p.IsWholesale, dbo.fn_CalculateProductProfit(p.Id) AS UnitProfit, (p.Stock * p.CostPrice) AS InventoryAssetValue,
    CASE WHEN p.Stock = 0 THEN 'Out of Stock' WHEN p.Stock <= p.LowStockThreshold THEN 'Low Stock' ELSE 'In Stock' END AS StockStatus
FROM Products p;
GO

CREATE VIEW uv_OrderSummary
AS
SELECT o.Id AS OrderId, o.CustomerId, c.Name AS CustomerName, c.Phone AS CustomerPhone, o.MarketingOfficerId AS OfficerId, u.Name AS OfficerName, o.Total, o.Cost, o.GrossProfit, o.Status AS OrderStatus, o.PaymentStatus, o.CommissionPaid, o.Date AS OrderDate, o.DeliveryNotes, o.CreatedAt
FROM Orders o JOIN Customers c ON o.CustomerId = c.Id JOIN Users u ON o.MarketingOfficerId = u.Id;
GO

CREATE VIEW uv_CommissionSummary
AS
SELECT comm.OrderId, comm.UserId AS OfficerId, u.Name AS OfficerName, comm.CommissionPercentage, comm.CommissionAmount, comm.Status AS PayoutStatus, comm.PayoutId, o.Total AS OrderTotal, o.Status AS OrderStatus, comm.CreatedAt
FROM Commissions comm JOIN Users u ON comm.UserId = u.Id JOIN Orders o ON comm.OrderId = o.Id;
GO

CREATE VIEW uv_PayoutSummary
AS
SELECT pay.Id AS PayoutId, pay.UserId AS OfficerId, uOfficer.Name AS OfficerName, pay.Amount, pay.PaidBy AS AuthorizerId, uAuthorizer.Name AS AuthorizerName, pay.CreatedAt
FROM Payouts pay JOIN Users uOfficer ON pay.UserId = uOfficer.Id JOIN Users uAuthorizer ON pay.PaidBy = uAuthorizer.Id;
GO

CREATE VIEW uv_AuditLogSummary
AS
SELECT al.Id AS LogId, al.Category, al.Severity, al.Message, al.UserId, u.Name AS ActorName, u.RoleName AS ActorRole, al.TargetId, al.Metadata, al.Timestamp
FROM AuditLogs al LEFT JOIN Users u ON al.UserId = u.Id;
GO

CREATE VIEW uv_SystemHealthSummary
AS
SELECT si.Id AS IssueId, si.Title, si.Severity, si.Source, si.AffectedEntityType, si.AffectedEntityId, si.AffectedCount, si.Explanation, si.RecommendedAction, si.Repairable, si.CreatedAt, si.LastDetectedAt,
    (SELECT CASE WHEN 100 - SUM(CASE WHEN Severity = 'CRITICAL' THEN 20 WHEN Severity = 'ERROR' THEN 10 WHEN Severity = 'WARNING' THEN 5 ELSE 1 END) < 0 THEN 0 ELSE 100 - SUM(CASE WHEN Severity = 'CRITICAL' THEN 20 WHEN Severity = 'ERROR' THEN 10 WHEN Severity = 'WARNING' THEN 5 ELSE 1 END) END FROM SystemIssues) AS SystemHealthScore
FROM SystemIssues si;
GO

-- ============================================================================
-- PART 4: RELATIONAL STORED PROCEDURES
-- ============================================================================

DROP PROCEDURE IF EXISTS dbo.sp_WriteAuditLog;
GO
CREATE PROCEDURE dbo.sp_WriteAuditLog
    @Category NVARCHAR(50), @Severity NVARCHAR(20), @Message NVARCHAR(MAX), @UserId NVARCHAR(50) = NULL, @TargetId NVARCHAR(100) = NULL, @Metadata NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO AuditLogs (Category, Severity, Message, UserId, TargetId, Metadata)
    VALUES (@Category, @Severity, @Message, @UserId, @TargetId, @Metadata);
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_CreateUser;
GO
CREATE PROCEDURE dbo.sp_CreateUser
    @Id NVARCHAR(50), @Name NVARCHAR(150), @Email NVARCHAR(150), @Phone NVARCHAR(50), @PasswordHash NVARCHAR(255), @RoleName NVARCHAR(50), @CommissionPercentage DECIMAL(5, 2) = 5.00
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO Users (Id, Name, Email, Phone, PasswordHash, RoleName, CommissionPercentage)
        VALUES (@Id, @Name, @Email, @Phone, @PasswordHash, @RoleName, @CommissionPercentage);
        DECLARE @Msg NVARCHAR(MAX) = 'New user created: ' + @Name + ' (' + @RoleName + ')';
        EXEC dbo.sp_WriteAuditLog 'SECURITY', 'INFO', @Msg, NULL, @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_UpdateUserPermissions;
GO
CREATE PROCEDURE dbo.sp_UpdateUserPermissions
    @UserId NVARCHAR(50), @PermissionsCsv NVARCHAR(MAX), @UpdatedBy NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (SELECT 1 FROM Users WHERE Id = @UserId) THROW 50001, 'User record not found.', 1;
        DELETE FROM UserPermissions WHERE UserId = @UserId;
        INSERT INTO UserPermissions (UserId, PermissionCode)
        SELECT DISTINCT @UserId, RTRIM(LTRIM(value)) FROM STRING_SPLIT(@PermissionsCsv, ',') WHERE RTRIM(LTRIM(value)) IN (SELECT PermissionCode FROM Permissions);
        DECLARE @UserName NVARCHAR(150); SELECT @UserName = Name FROM Users WHERE Id = @UserId;
        DECLARE @Msg NVARCHAR(MAX) = 'User permissions customized for: ' + @UserName;
        EXEC dbo.sp_WriteAuditLog 'SECURITY', 'WARNING', @Msg, @UpdatedBy, @UserId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_CreateCustomer;
GO
CREATE PROCEDURE dbo.sp_CreateCustomer
    @Id NVARCHAR(50), @Name NVARCHAR(150), @Phone NVARCHAR(50), @RegisteredBy NVARCHAR(50), @MarketingOfficerId NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        INSERT INTO Customers (Id, Name, Phone, RegisteredBy, MarketingOfficerId)
        VALUES (@Id, @Name, @Phone, @RegisteredBy, ISNULL(@MarketingOfficerId, @RegisteredBy));
        DECLARE @Msg NVARCHAR(MAX) = 'Registered new customer: ' + @Name;
        EXEC dbo.sp_WriteAuditLog 'CRM', 'INFO', @Msg, @RegisteredBy, @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_AdjustInventory;
GO
CREATE PROCEDURE dbo.sp_AdjustInventory
    @ProductId NVARCHAR(50), @QuantityChange INT, @Reason NVARCHAR(255), @CreatedBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF NOT EXISTS (SELECT 1 FROM Products WHERE Id = @ProductId) THROW 50002, 'Product not found.', 1;
        DECLARE @CurrentStock INT; SELECT @CurrentStock = Stock FROM Products WHERE Id = @ProductId;
        IF (@CurrentStock + @QuantityChange) < 0 THROW 50003, 'Insufficient stock available. Stock levels cannot drop below 0.', 1;
        UPDATE Products SET Stock = Stock + @QuantityChange, UpdatedAt = SYSUTCDATETIME() WHERE Id = @ProductId;
        DECLARE @MovementId NVARCHAR(50) = 'MVT-' + CAST(NEWID() AS NVARCHAR(36));
        INSERT INTO InventoryMovements (Id, ProductId, QuantityChange, Reason, CreatedBy) VALUES (@MovementId, @ProductId, @QuantityChange, @Reason, @CreatedBy);
        DECLARE @ProductName NVARCHAR(150); SELECT @ProductName = Name FROM Products WHERE Id = @ProductId;
        DECLARE @Msg NVARCHAR(MAX) = 'Stock adjusted for ' + @ProductName + ': ' + CAST(@QuantityChange AS NVARCHAR(10)) + ' (' + @Reason + ')';
        EXEC dbo.sp_WriteAuditLog 'INVENTORY', 'INFO', @Msg, @CreatedBy, @ProductId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_CreateOrder;
GO
CREATE PROCEDURE dbo.sp_CreateOrder
    @Id NVARCHAR(50), @CustomerId NVARCHAR(50), @MarketingOfficerId NVARCHAR(50), @ProductId NVARCHAR(50), @Quantity INT, @Status NVARCHAR(50) = 'pending', @Notes NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        IF dbo.fn_CheckStockAvailability(@ProductId, @Quantity) = 0 THROW 50004, 'Insufficient stock available to complete this order.', 1;
        DECLARE @SellingPrice DECIMAL(18, 2); DECLARE @CostPrice DECIMAL(18, 2); DECLARE @ProductName NVARCHAR(150);
        SELECT @SellingPrice = SellingPrice, @CostPrice = CostPrice, @ProductName = Name FROM Products WHERE Id = @ProductId;
        DECLARE @Total DECIMAL(18,2) = @SellingPrice * @Quantity; DECLARE @Cost DECIMAL(18,2) = @CostPrice * @Quantity; DECLARE @GrossProfit DECIMAL(18,2) = @Total - @Cost;
        INSERT INTO Orders (Id, CustomerId, MarketingOfficerId, Total, Cost, GrossProfit, Status, PaymentStatus, DeliveryNotes) VALUES (@Id, @CustomerId, @MarketingOfficerId, @Total, @Cost, @GrossProfit, @Status, CASE WHEN @Status = 'paid' THEN 'paid' ELSE 'unpaid' END, @Notes);
        INSERT INTO OrderItems (OrderId, ProductId, Quantity, Price) VALUES (@Id, @ProductId, @Quantity, @SellingPrice);
        EXEC dbo.sp_AdjustInventory @ProductId, -@Quantity, 'Order Created', @MarketingOfficerId;
        DECLARE @OfficerCommissionPercent DECIMAL(5,2); SELECT @OfficerCommissionPercent = CommissionPercentage FROM Users WHERE Id = @MarketingOfficerId;
        DECLARE @CommAmount DECIMAL(18,2) = dbo.fn_CalculateCommissionAmount(@Total, @OfficerCommissionPercent);
        INSERT INTO Commissions (OrderId, UserId, CommissionPercentage, CommissionAmount, Status) VALUES (@Id, @MarketingOfficerId, @OfficerCommissionPercent, @CommAmount, 'pending');
        DECLARE @CustomerName NVARCHAR(150); SELECT @CustomerName = Name FROM Customers WHERE Id = @CustomerId;
        DECLARE @Msg NVARCHAR(MAX) = 'Placed order ' + @Id + ' for customer ' + @CustomerName + '. Amount: $' + CAST(@Total AS NVARCHAR(50));
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @MarketingOfficerId, @Id;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_UpdateOrderStatus;
GO
CREATE PROCEDURE dbo.sp_UpdateOrderStatus
    @OrderId NVARCHAR(50), @NewStatus NVARCHAR(50), @UpdatedBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @OldStatus NVARCHAR(50); DECLARE @CommissionPaid BIT;
        SELECT @OldStatus = Status, @CommissionPaid = CommissionPaid FROM Orders WHERE Id = @OrderId;
        IF @OldStatus IS NULL THROW 50005, 'Order not found.', 1;
        IF @CommissionPaid = 1
        BEGIN
            DECLARE @EligibleStatuses TABLE (Stat NVARCHAR(50));
            INSERT INTO @EligibleStatuses VALUES ('paid'), ('delivered'), ('successfully delivered'), ('completed');
            IF NOT EXISTS (SELECT 1 FROM @EligibleStatuses WHERE Stat = LOWER(@NewStatus)) THROW 50006, 'Cannot revert order status. Commission has already been paid out.', 1;
        END
        IF LOWER(@OldStatus) = 'cancelled' AND LOWER(@NewStatus) <> 'cancelled'
        BEGIN
            DECLARE @ProductId NVARCHAR(50); DECLARE @Qty INT; SELECT @ProductId = ProductId, @Qty = Quantity FROM OrderItems WHERE OrderId = @OrderId;
            IF dbo.fn_CheckStockAvailability(@ProductId, @Qty) = 0 THROW 50007, 'Insufficient stock available to restore this order.', 1;
            EXEC dbo.sp_AdjustInventory @ProductId, -@Qty, 'Restoring Cancelled Order', @UpdatedBy;
        END
        ELSE IF LOWER(@OldStatus) <> 'cancelled' AND LOWER(@NewStatus) = 'cancelled'
        BEGIN
            DECLARE @CancelProdId NVARCHAR(50); DECLARE @CancelQty INT; SELECT @CancelProdId = ProductId, @CancelQty = Quantity FROM OrderItems WHERE OrderId = @OrderId;
            EXEC dbo.sp_AdjustInventory @CancelProdId, @CancelQty, 'Order Cancelled', @UpdatedBy;
        END
        UPDATE Orders SET Status = @NewStatus, PaymentStatus = CASE WHEN LOWER(@NewStatus) = 'paid' THEN 'paid' ELSE PaymentStatus END, UpdatedAt = SYSUTCDATETIME() WHERE Id = @OrderId;
        DECLARE @Msg NVARCHAR(MAX) = 'Order #' + @OrderId + ' status updated from ' + @OldStatus + ' to ' + @NewStatus;
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @UpdatedBy, @OrderId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_ProcessCommissionPayout;
GO
CREATE PROCEDURE dbo.sp_ProcessCommissionPayout
    @PayoutId NVARCHAR(50), @OfficerId NVARCHAR(50), @PaidBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @OfficerName NVARCHAR(150); SELECT @OfficerName = Name FROM Users WHERE Id = @OfficerId;
        IF @OfficerName IS NULL THROW 50008, 'Officer record not found.', 1;
        DECLARE @EligibleAmount DECIMAL(18,2) = 0.00;
        SELECT @EligibleAmount = SUM(comm.CommissionAmount) FROM Commissions comm JOIN Orders o ON comm.OrderId = o.Id WHERE comm.UserId = @OfficerId AND comm.Status = 'pending' AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');
        IF ISNULL(@EligibleAmount, 0.00) < 0.01 THROW 50009, 'No new eligible commissions to pay out for this officer.', 1;
        INSERT INTO Payouts (Id, UserId, Amount, PaidBy) VALUES (@PayoutId, @OfficerId, @EligibleAmount, @PaidBy);
        UPDATE comm SET comm.Status = 'paid', comm.PayoutId = @PayoutId FROM Commissions comm JOIN Orders o ON comm.OrderId = o.Id WHERE comm.UserId = @OfficerId AND comm.Status = 'pending' AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');
        UPDATE o SET o.CommissionPaid = 1 FROM Orders o JOIN Commissions comm ON o.Id = comm.OrderId WHERE comm.PayoutId = @PayoutId;
        UPDATE Users SET PaidCommissionTotal = PaidCommissionTotal + @EligibleAmount, PendingCommissionTotal = 0, UpdatedAt = SYSUTCDATETIME() WHERE Id = @OfficerId;
        DECLARE @Msg NVARCHAR(MAX) = 'Processed commission payout of $' + CAST(@EligibleAmount AS NVARCHAR(20)) + ' for ' + @OfficerName;
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @PaidBy, @OfficerId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_RecalculateCommissions;
GO
CREATE PROCEDURE dbo.sp_RecalculateCommissions
    @OfficerId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        DECLARE @CommissionPercentage DECIMAL(5,2); SELECT @CommissionPercentage = CommissionPercentage FROM Users WHERE Id = @OfficerId;
        IF @CommissionPercentage IS NULL RETURN;
        DECLARE @Earned DECIMAL(18,2) = 0.00;
        SELECT @Earned = SUM((o.Total * @CommissionPercentage) / 100.00) FROM Orders o WHERE o.MarketingOfficerId = @OfficerId AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');
        SET @Earned = ISNULL(@Earned, 0.00);
        DECLARE @PaidTotal DECIMAL(18,2); SELECT @PaidTotal = PaidCommissionTotal FROM Users WHERE Id = @OfficerId;
        UPDATE Users SET EarnedCommissionTotal = @Earned, PendingCommissionTotal = CASE WHEN (@Earned - @PaidTotal) < 0 THEN 0.00 ELSE (@Earned - @PaidTotal) END, UpdatedAt = SYSUTCDATETIME() WHERE Id = @OfficerId;
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION; THROW;
    END CATCH
END;
GO

DROP PROCEDURE IF EXISTS dbo.sp_ValidateDataIntegrity;
GO
CREATE PROCEDURE dbo.sp_ValidateDataIntegrity
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM SystemIssues;
    
    DECLARE @NegCount INT = 0; SELECT @NegCount = COUNT(*) FROM Products WHERE Stock < 0;
    IF @NegCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES ('inv-neg', 'Negative Inventory Detected', 'ERROR', 'Inventory Control', 'Product', @NegCount, 'System records show stock levels below zero.', 'Reset negative stock levels to zero.', 1);
    END

    DECLARE @InvalidPermCount INT = 0; SELECT @InvalidPermCount = COUNT(DISTINCT up.UserId) FROM UserPermissions up WHERE up.PermissionCode NOT IN (SELECT PermissionCode FROM Permissions);
    IF @InvalidPermCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES ('invalid-permissions', 'Invalid Permission Assignments', 'ERROR', 'Auth Service', 'AdminUser', @InvalidPermCount, 'Users have permission codes assigned that do not exist in the official permission registry.', 'Purge unregistered permission records.', 1);
    END

    DECLARE @MismatchedCount INT = 0; SELECT @MismatchedCount = COUNT(*) FROM Orders o WHERE ABS(o.Total - (SELECT SUM(Quantity * Price) FROM OrderItems WHERE OrderId = o.Id)) > 0.01;
    IF @MismatchedCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES ('mismatched-order-totals', 'Invalid Order Totals', 'CRITICAL', 'Order Engine', 'Order', @MismatchedCount, 'Order totals mismatch item balances.', 'Trigger re-calculation stored procedure.', 1);
    END

    DECLARE @OrphanCust INT = 0; SELECT @OrphanCust = COUNT(*) FROM Customers WHERE RegisteredBy NOT IN (SELECT Id FROM Users);
    IF @OrphanCust > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES ('orphaned-customers', 'Orphaned Customer Records', 'WARNING', 'CRM Database', 'Customer', @OrphanCust, 'Customers are linked to administrative accounts that no longer exist.', 'Assign records to Super Admin.', 1);
    END
END;
GO

-- ============================================================================
-- PART 5: SYSTEM TESTING SEED DATA
-- ============================================================================

DELETE FROM UserPermissions;
DELETE FROM Customers;
DELETE FROM Products;
DELETE FROM Settings;
DELETE FROM Users;
DELETE FROM Permissions;
DELETE FROM Roles;
GO

INSERT INTO Roles (RoleName, Description) VALUES 
('Super Admin', 'Full systemic operational control and financial lock bypass privileges.'),
('Manager', 'General warehouse monitoring and CRM operations management.'),
('Marketing Officer', 'Customer registrations and direct sales placements.'),
('Inventory Staff', 'Product catalog maintenance and manual stock adjustments.'),
('Delivery Staff', 'Order dispatching and courier tracking operations.');

INSERT INTO Permissions (PermissionCode, Description, Category) VALUES
('view_dashboard', 'Access real-time analytics dashboard charts.', 'General'),
('change_settings', 'Modify system settings parameters.', 'General'),
('manage_users', 'Administer backoffice staff accounts.', 'General'),
('view_products', 'Browse wholesale football catalogs.', 'Inventory'),
('add_products', 'Introduce new product items to catalog.', 'Inventory'),
('edit_products', 'Modify existing product specifications.', 'Inventory'),
('delete_products', 'Permanently remove product items from database.', 'Inventory'),
('view_inventory', 'Observe real-time stock levels.', 'Inventory'),
('adjust_stock', 'Perform manual stock adjustments.', 'Inventory'),
('view_orders', 'Browse all system order histories.', 'Orders'),
('create_orders', 'Create sales orders.', 'Orders'),
('edit_orders', 'Update order statuses.', 'Orders'),
('delete_orders', 'Remove order entries.', 'Orders'),
('view_customers', 'Browse customer CRM lists.', 'CRM'),
('add_customers', 'Register new CRM customer entries.', 'CRM'),
('edit_customers', 'Modify customer metadata.', 'CRM'),
('delete_customers', 'Remove customers.', 'CRM'),
('view_reports', 'Review financial and commission charts.', 'Finance'),
('view_commissions', 'Access sales commission payout logs.', 'Finance'),
('mark_commissions_paid', 'Authorize and register commission lockouts.', 'Finance'),
('view_diagnostics', 'Access system health diagnostic reports.', 'System'),
('view_audit_trail', 'Browse backoffice activity audit records.', 'System'),
('manage_system', 'Initiate backup restores and hard resets.', 'System'),
('view_all_customers', 'Access the full customer database.', 'Customer Visibility'),
('view_own_customers_only', 'Restrict visibility to personally registered customers.', 'Customer Visibility');

INSERT INTO Users (Id, Name, Email, Phone, PasswordHash, RoleName, Status, CommissionPercentage) VALUES 
('u-admin100', 'Executive Admin', 'admin@efz.com', '+252-615-999999', '$2b$10$R9hZPH2y4/1wW/67kO97AOFGv.B74rA.g8Xq4r.62tG4c6V3g3yKu', 'Super Admin', 'active', 0.00);

INSERT INTO UserPermissions (UserId, PermissionCode)
SELECT 'u-admin100', PermissionCode FROM Permissions WHERE PermissionCode <> 'view_own_customers_only';

INSERT INTO Settings (SettingKey, SettingValue, Description) VALUES
('SYSTEM_NAME', 'EFZ Wholesale Football Platform', 'Display branding name.'),
('AUTO_BACKUP', 'true', 'Flag to enable automated snapshot creation.'),
('COMMISSION_DEFAULT_PERCENT', '5.00', 'Baseline commission for newly registered officers.'),
('LOW_STOCK_GLOBAL_LIMIT', '30', 'Fallback low stock notification boundary.');

INSERT INTO Products (Id, Name, Category, Price, CostPrice, SellingPrice, Stock, LowStockThreshold, Size, Description, Durability, SurfaceType, IsWholesale) VALUES
('prod-fb-premier', 'Premier League Elite Football', 'Leather Footballs', 45.00, 25.00, 45.00, 120, 20, 'Size 5', 'Matchball of the English top-tier.', 'High-Grade', 'Grass', 1),
('prod-fb-champs', 'Champions Pro Star Ball', 'Leather Footballs', 50.00, 30.00, 50.00, 80, 15, 'Size 5', 'Star paneled matchball.', 'Extreme', 'Grass', 1),
('prod-fb-street', 'Street Asphalt Hardener', 'Rubber Footballs', 25.00, 12.00, 25.00, 250, 40, 'Size 4', 'Tough rubberized ball built for concrete.', 'Indestructible', 'Concrete/Street', 1),
('prod-fb-futsal', 'Futsal Low-Bounce Core', 'Futsal Footballs', 35.00, 18.00, 35.00, 60, 10, 'Standard', 'Low bounce heavy bladder ball.', 'Premium', 'Indoor Court', 1),
('prod-fb-retro', 'Retro 1970 Leather Classic', 'Vintage Footballs', 60.00, 35.00, 60.00, 30, 5, 'Size 5', 'Classic brown stitched leather.', 'Medium', 'Display', 1);

INSERT INTO Customers (Id, Name, Phone, RegisteredBy, MarketingOfficerId) VALUES
('c-test777', 'Mogadishu FC Athletics', '+252-615-111111', 'u-admin100', 'u-admin100');
GO

PRINT '========================================================================'
PRINT 'EFZ MICROSOFT SQL SERVER MASTER INSTALLATION COMPLETE.'
PRINT 'DATABASE: football'
PRINT 'CREATED ENTIRE SCHEMA, VIEWS, FUNCTIONS, STORED PROCEDURES & MOCK SEEDS.'
PRINT '========================================================================'
GO
