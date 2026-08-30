-- ============================================================================
-- EFZ Microsoft SQL Server Business Logic Functions
-- Database: football
-- ============================================================================

USE football;
GO

-- Drop existing functions to allow clean overwrite
DROP FUNCTION IF EXISTS dbo.fn_CalculateProductProfit;
DROP FUNCTION IF EXISTS dbo.fn_CalculateOrderGrossProfit;
DROP FUNCTION IF EXISTS dbo.fn_CalculateCommissionAmount;
DROP FUNCTION IF EXISTS dbo.fn_CheckStockAvailability;
DROP FUNCTION IF EXISTS dbo.fn_CalculateInventoryValue;
GO

-- ==========================================
-- 1. Calculate Product Profit Margin (Unit-Level)
-- ==========================================
CREATE FUNCTION dbo.fn_CalculateProductProfit (
    @ProductId NVARCHAR(50)
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @Profit DECIMAL(18, 2) = 0.00;
    
    SELECT @Profit = (SellingPrice - CostPrice)
    FROM Products
    WHERE Id = @ProductId;
    
    RETURN ISNULL(@Profit, 0.00);
END;
GO

-- ==========================================
-- 2. Calculate Order Gross Profit
-- ==========================================
CREATE FUNCTION dbo.fn_CalculateOrderGrossProfit (
    @OrderId NVARCHAR(50)
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @GrossProfit DECIMAL(18, 2) = 0.00;
    
    SELECT @GrossProfit = SUM((oi.Price - p.CostPrice) * oi.Quantity)
    FROM OrderItems oi
    JOIN Products p ON oi.ProductId = p.Id
    WHERE oi.OrderId = @OrderId;
    
    RETURN ISNULL(@GrossProfit, 0.00);
END;
GO

-- ==========================================
-- 3. Calculate Commission Amount
-- ==========================================
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

-- ==========================================
-- 4. Check Stock Availability
-- ==========================================
CREATE FUNCTION dbo.fn_CheckStockAvailability (
    @ProductId NVARCHAR(50),
    @RequestedQuantity INT
)
RETURNS BIT
AS
BEGIN
    DECLARE @IsAvailable BIT = 0;
    DECLARE @CurrentStock INT = 0;
    
    SELECT @CurrentStock = Stock
    FROM Products
    WHERE Id = @ProductId;
    
    IF @CurrentStock >= @RequestedQuantity AND @RequestedQuantity > 0
    BEGIN
        SET @IsAvailable = 1;
    END
    
    RETURN @IsAvailable;
END;
GO

-- ==========================================
-- 5. Calculate Total Inventory Portfolio Value
-- ==========================================
CREATE FUNCTION dbo.fn_CalculateInventoryValue (
    @CategoryFilter NVARCHAR(100) = NULL
)
RETURNS DECIMAL(18, 2)
AS
BEGIN
    DECLARE @TotalValue DECIMAL(18, 2) = 0.00;
    
    SELECT @TotalValue = SUM(Stock * CostPrice)
    FROM Products
    WHERE (@CategoryFilter IS NULL OR Category = @CategoryFilter);
    
    RETURN ISNULL(@TotalValue, 0.00);
END;
GO
