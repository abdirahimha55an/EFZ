-- ============================================================================
-- EFZ Microsoft SQL Server Stored Procedures
-- Database: football
-- ============================================================================

USE football;
GO

-- Drop existing procedures to allow clean compile
DROP PROCEDURE IF EXISTS dbo.sp_WriteAuditLog;
DROP PROCEDURE IF EXISTS dbo.sp_CreateUser;
DROP PROCEDURE IF EXISTS dbo.sp_UpdateUserPermissions;
DROP PROCEDURE IF EXISTS dbo.sp_CreateCustomer;
DROP PROCEDURE IF EXISTS dbo.sp_AdjustInventory;
DROP PROCEDURE IF EXISTS dbo.sp_CreateOrder;
DROP PROCEDURE IF EXISTS dbo.sp_UpdateOrderStatus;
DROP PROCEDURE IF EXISTS dbo.sp_ProcessCommissionPayout;
DROP PROCEDURE IF EXISTS dbo.sp_RecalculateCommissions;
DROP PROCEDURE IF EXISTS dbo.sp_ValidateDataIntegrity;
GO

-- ==========================================
-- 1. Stored Procedure: Write Audit Log
-- ==========================================
CREATE PROCEDURE dbo.sp_WriteAuditLog
    @Category NVARCHAR(50),
    @Severity NVARCHAR(20),
    @Message NVARCHAR(MAX),
    @UserId NVARCHAR(50) = NULL,
    @TargetId NVARCHAR(100) = NULL,
    @Metadata NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO AuditLogs (Category, Severity, Message, UserId, TargetId, Metadata)
    VALUES (@Category, @Severity, @Message, @UserId, @TargetId, @Metadata);
END;
GO

-- ==========================================
-- 2. Stored Procedure: Create User
-- ==========================================
CREATE PROCEDURE dbo.sp_CreateUser
    @Id NVARCHAR(50),
    @Name NVARCHAR(150),
    @Email NVARCHAR(150),
    @Phone NVARCHAR(50),
    @PasswordHash NVARCHAR(255),
    @RoleName NVARCHAR(50),
    @CommissionPercentage DECIMAL(5, 2) = 5.00
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;
        
        INSERT INTO Users (Id, Name, Email, Phone, PasswordHash, RoleName, CommissionPercentage)
        VALUES (@Id, @Name, @Email, @Phone, @PasswordHash, @RoleName, @CommissionPercentage);

        -- Log Action
        DECLARE @Msg NVARCHAR(MAX) = 'New administrative user created: ' + @Name + ' (' + @RoleName + ')';
        EXEC dbo.sp_WriteAuditLog 'SECURITY', 'INFO', @Msg, NULL, @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 3. Stored Procedure: Update User Permissions
-- ==========================================
CREATE PROCEDURE dbo.sp_UpdateUserPermissions
    @UserId NVARCHAR(50),
    @PermissionsCsv NVARCHAR(MAX),
    @UpdatedBy NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Verify User Exists
        IF NOT EXISTS (SELECT 1 FROM Users WHERE Id = @UserId)
        BEGIN
            THROW 50001, 'User record not found.', 1;
        END

        -- Delete Existing Permissions
        DELETE FROM UserPermissions WHERE UserId = @UserId;

        -- Split CSV and Insert Custom Permissions
        INSERT INTO UserPermissions (UserId, PermissionCode)
        SELECT DISTINCT @UserId, RTRIM(LTRIM(value))
        FROM STRING_SPLIT(@PermissionsCsv, ',')
        WHERE RTRIM(LTRIM(value)) IN (SELECT PermissionCode FROM Permissions);

        -- Log Action
        DECLARE @UserName NVARCHAR(150);
        SELECT @UserName = Name FROM Users WHERE Id = @UserId;
        DECLARE @Msg NVARCHAR(MAX) = 'User permissions customized for: ' + @UserName;
        EXEC dbo.sp_WriteAuditLog 'SECURITY', 'WARNING', @Msg, @UpdatedBy, @UserId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 4. Stored Procedure: Create Customer
-- ==========================================
CREATE PROCEDURE dbo.sp_CreateCustomer
    @Id NVARCHAR(50),
    @Name NVARCHAR(150),
    @Phone NVARCHAR(50),
    @RegisteredBy NVARCHAR(50),
    @MarketingOfficerId NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        INSERT INTO Customers (Id, Name, Phone, RegisteredBy, MarketingOfficerId)
        VALUES (@Id, @Name, @Phone, @RegisteredBy, ISNULL(@MarketingOfficerId, @RegisteredBy));

        -- Log Action
        DECLARE @Msg NVARCHAR(MAX) = 'Registered new customer: ' + @Name;
        EXEC dbo.sp_WriteAuditLog 'CRM', 'INFO', @Msg, @RegisteredBy, @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 5. Stored Procedure: Adjust Product Inventory
-- ==========================================
CREATE PROCEDURE dbo.sp_AdjustInventory
    @ProductId NVARCHAR(50),
    @QuantityChange INT,
    @Reason NVARCHAR(255),
    @CreatedBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Check Product
        IF NOT EXISTS (SELECT 1 FROM Products WHERE Id = @ProductId)
        BEGIN
            THROW 50002, 'Product not found.', 1;
        END

        DECLARE @CurrentStock INT;
        SELECT @CurrentStock = Stock FROM Products WHERE Id = @ProductId;

        -- Enforce negative stock prevention rule
        IF (@CurrentStock + @QuantityChange) < 0
        BEGIN
            THROW 50003, 'Insufficient stock available. Inventory levels cannot fall below zero.', 1;
        END

        -- Perform update
        UPDATE Products
        SET Stock = Stock + @QuantityChange,
            UpdatedAt = SYSUTCDATETIME()
        WHERE Id = @ProductId;

        -- Record movement
        DECLARE @MovementId NVARCHAR(50) = 'MVT-' + CAST(NEWID() AS NVARCHAR(36));
        INSERT INTO InventoryMovements (Id, ProductId, QuantityChange, Reason, CreatedBy)
        VALUES (@MovementId, @ProductId, @QuantityChange, @Reason, @CreatedBy);

        -- Log Action
        DECLARE @ProductName NVARCHAR(150);
        SELECT @ProductName = Name FROM Products WHERE Id = @ProductId;
        DECLARE @Msg NVARCHAR(MAX) = 'Stock adjusted for ' + @ProductName + ': ' + CAST(@QuantityChange AS NVARCHAR(10)) + ' (' + @Reason + ')';
        EXEC dbo.sp_WriteAuditLog 'INVENTORY', 'INFO', @Msg, @CreatedBy, @ProductId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 6. Stored Procedure: Create Order
-- ==========================================
CREATE PROCEDURE dbo.sp_CreateOrder
    @Id NVARCHAR(50),
    @CustomerId NVARCHAR(50),
    @MarketingOfficerId NVARCHAR(50),
    @ProductId NVARCHAR(50),
    @Quantity INT,
    @Status NVARCHAR(50) = 'pending',
    @Notes NVARCHAR(MAX) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Validate stock availability
        IF dbo.fn_CheckStockAvailability(@ProductId, @Quantity) = 0
        BEGIN
            THROW 50004, 'Insufficient stock available to complete this order.', 1;
        END

        -- Fetch prices
        DECLARE @SellingPrice DECIMAL(18, 2);
        DECLARE @CostPrice DECIMAL(18, 2);
        DECLARE @ProductName NVARCHAR(150);
        
        SELECT @SellingPrice = SellingPrice, @CostPrice = CostPrice, @ProductName = Name 
        FROM Products WHERE Id = @ProductId;

        DECLARE @Total DECIMAL(18,2) = @SellingPrice * @Quantity;
        DECLARE @Cost DECIMAL(18,2) = @CostPrice * @Quantity;
        DECLARE @GrossProfit DECIMAL(18,2) = @Total - @Cost;

        -- Insert Order
        INSERT INTO Orders (Id, CustomerId, MarketingOfficerId, Total, Cost, GrossProfit, Status, PaymentStatus, DeliveryNotes)
        VALUES (@Id, @CustomerId, @MarketingOfficerId, @Total, @Cost, @GrossProfit, @Status, 
                CASE WHEN @Status = 'paid' THEN 'paid' ELSE 'unpaid' END, @Notes);

        -- Insert OrderItem
        INSERT INTO OrderItems (OrderId, ProductId, Quantity, Price)
        VALUES (@Id, @ProductId, @Quantity, @SellingPrice);

        -- Deduct inventory
        EXEC dbo.sp_AdjustInventory @ProductId, -@Quantity, 'Order Created', @MarketingOfficerId;

        -- Create pending commission record for Marketing Officer
        DECLARE @OfficerCommissionPercent DECIMAL(5,2);
        SELECT @OfficerCommissionPercent = CommissionPercentage FROM Users WHERE Id = @MarketingOfficerId;
        
        DECLARE @CommAmount DECIMAL(18,2) = dbo.fn_CalculateCommissionAmount(@Total, @OfficerCommissionPercent);

        INSERT INTO Commissions (OrderId, UserId, CommissionPercentage, CommissionAmount, Status)
        VALUES (@Id, @MarketingOfficerId, @OfficerCommissionPercent, @CommAmount, 'pending');

        -- Log Action
        DECLARE @CustomerName NVARCHAR(150);
        SELECT @CustomerName = Name FROM Customers WHERE Id = @CustomerId;
        DECLARE @Msg NVARCHAR(MAX) = 'Placed order ' + @Id + ' for customer ' + @CustomerName + '. Amount: $' + CAST(@Total AS NVARCHAR(50));
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @MarketingOfficerId, @Id;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 7. Stored Procedure: Update Order Status
-- ==========================================
CREATE PROCEDURE dbo.sp_UpdateOrderStatus
    @OrderId NVARCHAR(50),
    @NewStatus NVARCHAR(50),
    @UpdatedBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @OldStatus NVARCHAR(50);
        DECLARE @CommissionPaid BIT;
        
        SELECT @OldStatus = Status, @CommissionPaid = CommissionPaid 
        FROM Orders WHERE Id = @OrderId;

        IF @OldStatus IS NULL
        BEGIN
            THROW 50005, 'Order not found.', 1;
        END

        -- Enforce reversion lock if commission is already paid
        IF @CommissionPaid = 1
        BEGIN
            DECLARE @EligibleStatuses TABLE (Stat NVARCHAR(50));
            INSERT INTO @EligibleStatuses VALUES ('paid'), ('delivered'), ('successfully delivered'), ('completed');
            
            IF NOT EXISTS (SELECT 1 FROM @EligibleStatuses WHERE Stat = LOWER(@NewStatus))
            BEGIN
                THROW 50006, 'Cannot revert order status. Commission has already been paid out.', 1;
            END
        END

        -- Inventory stock protection: transitions to/from cancelled status
        IF LOWER(@OldStatus) = 'cancelled' AND LOWER(@NewStatus) <> 'cancelled'
        BEGIN
            -- Restore cancelled order: Re-deduct stock
            DECLARE @ProductId NVARCHAR(50);
            DECLARE @Qty INT;
            SELECT @ProductId = ProductId, @Qty = Quantity FROM OrderItems WHERE OrderId = @OrderId;

            IF dbo.fn_CheckStockAvailability(@ProductId, @Qty) = 0
            BEGIN
                THROW 50007, 'Insufficient stock available to restore this order.', 1;
            END

            EXEC dbo.sp_AdjustInventory @ProductId, -@Qty, 'Restoring Cancelled Order', @UpdatedBy;
        END
        ELSE IF LOWER(@OldStatus) <> 'cancelled' AND LOWER(@NewStatus) = 'cancelled'
        BEGIN
            -- Cancel order: Return stock
            DECLARE @CancelProdId NVARCHAR(50);
            DECLARE @CancelQty INT;
            SELECT @CancelProdId = ProductId, @CancelQty = Quantity FROM OrderItems WHERE OrderId = @OrderId;

            EXEC dbo.sp_AdjustInventory @CancelProdId, @CancelQty, 'Order Cancelled', @UpdatedBy;
        END

        -- Update Order
        UPDATE Orders
        SET Status = @NewStatus,
            PaymentStatus = CASE WHEN LOWER(@NewStatus) = 'paid' THEN 'paid' ELSE PaymentStatus END,
            UpdatedAt = SYSUTCDATETIME()
        WHERE Id = @OrderId;

        -- Log Action
        DECLARE @Msg NVARCHAR(MAX) = 'Order #' + @OrderId + ' status updated from ' + @OldStatus + ' to ' + @NewStatus;
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @UpdatedBy, @OrderId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 8. Stored Procedure: Process Commission Payout
-- ==========================================
CREATE PROCEDURE dbo.sp_ProcessCommissionPayout
    @PayoutId NVARCHAR(50),
    @OfficerId NVARCHAR(50),
    @PaidBy NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        -- Verify Officer exists
        DECLARE @OfficerName NVARCHAR(150);
        SELECT @OfficerName = Name FROM Users WHERE Id = @OfficerId;
        IF @OfficerName IS NULL
        BEGIN
            THROW 50008, 'Officer record not found.', 1;
        END

        -- Summarize unpaid commissions on paid/delivered orders
        DECLARE @EligibleAmount DECIMAL(18,2) = 0.00;
        
        SELECT @EligibleAmount = SUM(comm.CommissionAmount)
        FROM Commissions comm
        JOIN Orders o ON comm.OrderId = o.Id
        WHERE comm.UserId = @OfficerId 
          AND comm.Status = 'pending'
          AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');

        IF ISNULL(@EligibleAmount, 0.00) < 0.01
        BEGIN
            THROW 50009, 'No new eligible commissions to pay out for this officer.', 1;
        END

        -- Record payout transaction
        INSERT INTO Payouts (Id, UserId, Amount, PaidBy)
        VALUES (@PayoutId, @OfficerId, @EligibleAmount, @PaidBy);

        -- Lock commissions and associate with this payout
        UPDATE comm
        SET comm.Status = 'paid',
            comm.PayoutId = @PayoutId
        FROM Commissions comm
        JOIN Orders o ON comm.OrderId = o.Id
        WHERE comm.UserId = @OfficerId 
          AND comm.Status = 'pending'
          AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');

        -- Set order commission lock
        UPDATE o
        SET o.CommissionPaid = 1
        FROM Orders o
        JOIN Commissions comm ON o.Id = comm.OrderId
        WHERE comm.PayoutId = @PayoutId;

        -- Update officer totals
        UPDATE Users
        SET PaidCommissionTotal = PaidCommissionTotal + @EligibleAmount,
            PendingCommissionTotal = 0,
            UpdatedAt = SYSUTCDATETIME()
        WHERE Id = @OfficerId;

        -- Log Action
        DECLARE @Msg NVARCHAR(MAX) = 'Processed commission payout of $' + CAST(@EligibleAmount AS NVARCHAR(20)) + ' for ' + @OfficerName;
        EXEC dbo.sp_WriteAuditLog 'FINANCIAL', 'INFO', @Msg, @PaidBy, @OfficerId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 9. Stored Procedure: Recalculate Commissions
-- ==========================================
CREATE PROCEDURE dbo.sp_RecalculateCommissions
    @OfficerId NVARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        DECLARE @CommissionPercentage DECIMAL(5,2);
        SELECT @CommissionPercentage = CommissionPercentage FROM Users WHERE Id = @OfficerId;

        IF @CommissionPercentage IS NULL RETURN;

        -- Recalculate total earned commissions from active paid/delivered orders
        DECLARE @Earned DECIMAL(18,2) = 0.00;
        
        SELECT @Earned = SUM((o.Total * @CommissionPercentage) / 100.00)
        FROM Orders o
        WHERE o.MarketingOfficerId = @OfficerId
          AND o.Status IN ('paid', 'delivered', 'successfully delivered', 'completed');

        SET @Earned = ISNULL(@Earned, 0.00);

        -- Update Users table
        DECLARE @PaidTotal DECIMAL(18,2);
        SELECT @PaidTotal = PaidCommissionTotal FROM Users WHERE Id = @OfficerId;

        UPDATE Users
        SET EarnedCommissionTotal = @Earned,
            PendingCommissionTotal = CASE WHEN (@Earned - @PaidTotal) < 0 THEN 0.00 ELSE (@Earned - @PaidTotal) END,
            UpdatedAt = SYSUTCDATETIME()
        WHERE Id = @OfficerId;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

-- ==========================================
-- 10. Stored Procedure: Validate Data Integrity
-- ==========================================
CREATE PROCEDURE dbo.sp_ValidateDataIntegrity
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = SYSUTCDATETIME();

    -- Clean repaired issues
    DELETE FROM SystemIssues;

    -- Heuristic 1: Negative Inventory Check
    DECLARE @NegCount INT = 0;
    SELECT @NegCount = COUNT(*) FROM Products WHERE Stock < 0;
    
    IF @NegCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES (
            'inv-neg',
            'Negative Inventory Detected',
            'ERROR',
            'Inventory Control',
            'Product',
            @NegCount,
            'System records show stock levels below zero, indicating untracked sales or faulty manual stock adjustments.',
            'Reset negative stock levels to zero in catalog.',
            1
        );
    END

    -- Heuristic 2: Invalid User Permissions
    DECLARE @InvalidPermCount INT = 0;
    SELECT @InvalidPermCount = COUNT(DISTINCT up.UserId)
    FROM UserPermissions up
    WHERE up.PermissionCode NOT IN (SELECT PermissionCode FROM Permissions);

    IF @InvalidPermCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES (
            'invalid-permissions',
            'Invalid Permission Assignments',
            'ERROR',
            'Auth Service',
            'AdminUser',
            @InvalidPermCount,
            'Users have permission codes assigned that do not exist in the official permission registry. This usually stems from deprecated parameters or faulty data import.',
            'Purge all unregistered permission records.',
            1
        );
    END

    -- Heuristic 3: Mismatched Order Totals
    DECLARE @MismatchedCount INT = 0;
    SELECT @MismatchedCount = COUNT(*)
    FROM Orders o
    WHERE ABS(o.Total - (SELECT SUM(Quantity * Price) FROM OrderItems WHERE OrderId = o.Id)) > 0.01;

    IF @MismatchedCount > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES (
            'mismatched-order-totals',
            'Invalid Order Totals',
            'CRITICAL',
            'Order Engine',
            'Order',
            @MismatchedCount,
            'Order totals mismatch the accumulated item values. This indicates calculation faults or data import drift.',
            'Trigger a recalculation stored procedure over target order IDs.',
            1
        );
    END

    -- Heuristic 4: Orphaned Customers
    DECLARE @OrphanCust INT = 0;
    SELECT @OrphanCust = COUNT(*) FROM Customers WHERE RegisteredBy NOT IN (SELECT Id FROM Users);

    IF @OrphanCust > 0
    BEGIN
        INSERT INTO SystemIssues (Id, Title, Severity, Source, AffectedEntityType, AffectedCount, Explanation, RecommendedAction, Repairable)
        VALUES (
            'orphaned-customers',
            'Orphaned Customer Records',
            'WARNING',
            'CRM Database',
            'Customer',
            @OrphanCust,
            'Customers are linked to administrative accounts that no longer exist.',
            'Assign orphan records to the Super Admin user.',
            1
        );
    END
END;
GO
