-- ============================================================================
-- EFZ Microsoft SQL Server Aggregation Views
-- Database: football
-- ============================================================================

USE football;
GO

-- Drop existing views to allow clean overwrite
DROP VIEW IF EXISTS uv_SystemHealthSummary;
DROP VIEW IF EXISTS uv_AuditLogSummary;
DROP VIEW IF EXISTS uv_PayoutSummary;
DROP VIEW IF EXISTS uv_CommissionSummary;
DROP VIEW IF EXISTS uv_OrderSummary;
DROP VIEW IF EXISTS uv_InventorySummary;
DROP VIEW IF EXISTS uv_CustomerOwnershipSummary;
DROP VIEW IF EXISTS uv_UserPermissionSummary;
GO

-- ==========================================
-- 1. User Privilege and Permissions Summary
-- ==========================================
CREATE VIEW uv_UserPermissionSummary
AS
SELECT 
    u.Id AS UserId,
    u.Name AS UserName,
    u.Email,
    u.Phone,
    u.RoleName,
    u.Status,
    u.CommissionPercentage,
    u.EarnedCommissionTotal,
    u.PendingCommissionTotal,
    u.PaidCommissionTotal,
    STRING_AGG(up.PermissionCode, ',') WITHIN GROUP (ORDER BY up.PermissionCode) AS PermissionsList,
    u.CreatedAt
FROM Users u
LEFT JOIN UserPermissions up ON u.Id = up.UserId
GROUP BY 
    u.Id, u.Name, u.Email, u.Phone, u.RoleName, u.Status, 
    u.CommissionPercentage, u.EarnedCommissionTotal, u.PendingCommissionTotal, u.PaidCommissionTotal, u.CreatedAt;
GO

-- ==========================================
-- 2. Customer Registry and Ownership Summary
-- ==========================================
CREATE VIEW uv_CustomerOwnershipSummary
AS
SELECT 
    c.Id AS CustomerId,
    c.Name AS CustomerName,
    c.Phone AS CustomerPhone,
    c.RegisteredBy AS CreatorId,
    uCreator.Name AS CreatorName,
    c.MarketingOfficerId AS OfficerId,
    uOfficer.Name AS OfficerName,
    c.CreatedAt
FROM Customers c
JOIN Users uCreator ON c.RegisteredBy = uCreator.Id
LEFT JOIN Users uOfficer ON c.MarketingOfficerId = uOfficer.Id;
GO

-- ==========================================
-- 3. Inventory and Profitability Summary
-- ==========================================
CREATE VIEW uv_InventorySummary
AS
SELECT 
    p.Id AS ProductId,
    p.Name AS ProductName,
    p.Category,
    p.Price,
    p.CostPrice,
    p.SellingPrice,
    p.Stock,
    p.LowStockThreshold,
    p.Size,
    p.IsWholesale,
    dbo.fn_CalculateProductProfit(p.Id) AS UnitProfit,
    (p.Stock * p.CostPrice) AS InventoryAssetValue,
    CASE 
        WHEN p.Stock = 0 THEN 'Out of Stock'
        WHEN p.Stock <= p.LowStockThreshold THEN 'Low Stock'
        ELSE 'In Stock'
    END AS StockStatus
FROM Products p;
GO

-- ==========================================
-- 4. Order and Gross Profit Summary
-- ==========================================
CREATE VIEW uv_OrderSummary
AS
SELECT 
    o.Id AS OrderId,
    o.CustomerId,
    c.Name AS CustomerName,
    c.Phone AS CustomerPhone,
    o.MarketingOfficerId AS OfficerId,
    u.Name AS OfficerName,
    o.Total,
    o.Cost,
    o.GrossProfit,
    o.Status AS OrderStatus,
    o.PaymentStatus,
    o.CommissionPaid,
    o.Date AS OrderDate,
    o.DeliveryNotes,
    o.CreatedAt
FROM Orders o
JOIN Customers c ON o.CustomerId = c.Id
JOIN Users u ON o.MarketingOfficerId = u.Id;
GO

-- ==========================================
-- 5. Marketing Officer Commissions Summary
-- ==========================================
CREATE VIEW uv_CommissionSummary
AS
SELECT 
    comm.OrderId,
    comm.UserId AS OfficerId,
    u.Name AS OfficerName,
    comm.CommissionPercentage,
    comm.CommissionAmount,
    comm.Status AS PayoutStatus,
    comm.PayoutId,
    o.Total AS OrderTotal,
    o.Status AS OrderStatus,
    comm.CreatedAt
FROM Commissions comm
JOIN Users u ON comm.UserId = u.Id
JOIN Orders o ON comm.OrderId = o.Id;
GO

-- ==========================================
-- 6. Commission Payout Logs
-- ==========================================
CREATE VIEW uv_PayoutSummary
AS
SELECT 
    pay.Id AS PayoutId,
    pay.UserId AS OfficerId,
    uOfficer.Name AS OfficerName,
    pay.Amount,
    pay.PaidBy AS AuthorizerId,
    uAuthorizer.Name AS AuthorizerName,
    pay.CreatedAt
FROM Payouts pay
JOIN Users uOfficer ON pay.UserId = uOfficer.Id
JOIN Users uAuthorizer ON pay.PaidBy = uAuthorizer.Id;
GO

-- ==========================================
-- 7. Audit Event Records
-- ==========================================
CREATE VIEW uv_AuditLogSummary
AS
SELECT 
    al.Id AS LogId,
    al.Category,
    al.Severity,
    al.Message,
    al.UserId,
    u.Name AS ActorName,
    u.RoleName AS ActorRole,
    al.TargetId,
    al.Metadata,
    al.Timestamp
FROM AuditLogs al
LEFT JOIN Users u ON al.UserId = u.Id;
GO

-- ==========================================
-- 8. System Issues and Health Index Score
-- ==========================================
CREATE VIEW uv_SystemHealthSummary
AS
SELECT 
    si.Id AS IssueId,
    si.Title,
    si.Severity,
    si.Source,
    si.AffectedEntityType,
    si.AffectedEntityId,
    si.AffectedCount,
    si.Explanation,
    si.RecommendedAction,
    si.Repairable,
    si.CreatedAt,
    si.LastDetectedAt,
    -- Determine systemic health impact (0-100 score heuristic)
    (
        SELECT CASE 
            WHEN 100 - SUM(
                CASE 
                    WHEN Severity = 'CRITICAL' THEN 20
                    WHEN Severity = 'ERROR' THEN 10
                    WHEN Severity = 'WARNING' THEN 5
                    ELSE 1
                END
            ) < 0 THEN 0
            ELSE 100 - SUM(
                CASE 
                    WHEN Severity = 'CRITICAL' THEN 20
                    WHEN Severity = 'ERROR' THEN 10
                    WHEN Severity = 'WARNING' THEN 5
                    ELSE 1
                END
            )
        END
        FROM SystemIssues
    ) AS SystemHealthScore
FROM SystemIssues si;
GO
