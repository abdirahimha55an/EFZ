-- ============================================================================
-- EFZ Microsoft SQL Server Seed Script
-- Database: football
-- ============================================================================

USE football;
GO

-- Clean seed targets
DELETE FROM UserPermissions;
DELETE FROM Customers;
DELETE FROM Products;
DELETE FROM Settings;
DELETE FROM Users;
DELETE FROM Permissions;
DELETE FROM Roles;
GO

-- ==========================================
-- 1. Seed Roles
-- ==========================================
INSERT INTO Roles (RoleName, Description) VALUES 
('Super Admin', 'Full systemic operational control and financial lock bypass privileges.'),
('Manager', 'General warehouse monitoring and CRM operations management.'),
('Marketing Officer', 'Customer registrations and direct sales placements.'),
('Inventory Staff', 'Product catalog maintenance and manual stock adjustments.'),
('Delivery Staff', 'Order dispatching and courier tracking operations.');

-- ==========================================
-- 2. Seed Official Permission Registry
-- ==========================================
INSERT INTO Permissions (PermissionCode, Description, Category) VALUES
-- General Category
('view_dashboard', 'Access real-time analytics dashboard charts.', 'General'),
('change_settings', 'Modify system settings parameters.', 'General'),
('manage_users', 'Administer backoffice staff accounts.', 'General'),
-- Inventory Category
('view_products', 'Browse wholesale football catalogs.', 'Inventory'),
('add_products', 'Introduce new product items to catalog.', 'Inventory'),
('edit_products', 'Modify existing product specifications.', 'Inventory'),
('delete_products', 'Permanently remove product items from database.', 'Inventory'),
('view_inventory', 'Observe real-time stock levels.', 'Inventory'),
('adjust_stock', 'Perform manual stock adjustments.', 'Inventory'),
-- Orders Category
('view_orders', 'Browse all system order histories.', 'Orders'),
('create_orders', 'Create sales orders.', 'Orders'),
('edit_orders', 'Update order statuses.', 'Orders'),
('delete_orders', 'Remove order entries.', 'Orders'),
-- CRM Category
('view_customers', 'Browse customer CRM lists.', 'CRM'),
('add_customers', 'Register new CRM customer entries.', 'CRM'),
('edit_customers', 'Modify customer metadata.', 'CRM'),
('delete_customers', 'Remove customers.', 'CRM'),
-- Finance Category
('view_reports', 'Review financial and commission charts.', 'Finance'),
('view_commissions', 'Access sales commission payout logs.', 'Finance'),
('mark_commissions_paid', 'Authorize and register commission lockouts.', 'Finance'),
-- System Category
('view_diagnostics', 'Access system health diagnostic reports.', 'System'),
('view_audit_trail', 'Browse backoffice activity audit records.', 'System'),
('manage_system', 'Initiate backup restores and hard resets.', 'System'),
-- Customer Visibility
('view_all_customers', 'Access the full customer database.', 'Customer Visibility'),
('view_own_customers_only', 'Restrict visibility to personally registered customers.', 'Customer Visibility');

-- ==========================================
-- 3. Seed Default Super Admin User
-- ==========================================
-- PasswordHash maps to a default bcrypt-compatible representation of 'password123'
INSERT INTO Users (Id, Name, Email, Phone, PasswordHash, RoleName, Status, CommissionPercentage) VALUES 
('u-admin100', 'Executive Admin', 'admin@efz.com', '+252-615-999999', '$2b$10$R9hZPH2y4/1wW/67kO97AOFGv.B74rA.g8Xq4r.62tG4c6V3g3yKu', 'Super Admin', 'active', 0.00);

-- Bind all permissions (except restricted view) to Super Admin
INSERT INTO UserPermissions (UserId, PermissionCode)
SELECT 'u-admin100', PermissionCode 
FROM Permissions 
WHERE PermissionCode <> 'view_own_customers_only';

-- ==========================================
-- 4. Seed Standard Settings
-- ==========================================
INSERT INTO Settings (SettingKey, SettingValue, Description) VALUES
('SYSTEM_NAME', 'EFZ Wholesale Football Platform', 'Display branding name.'),
('AUTO_BACKUP', 'true', 'Flag to enable automated snapshot creation.'),
('COMMISSION_DEFAULT_PERCENT', '5.00', 'Baseline commission for newly registered officers.'),
('LOW_STOCK_GLOBAL_LIMIT', '30', 'Fallback low stock notification boundary.');

-- ==========================================
-- 5. Seed Catalog of Products (Mock Catalog)
-- ==========================================
INSERT INTO Products (Id, Name, Category, Price, CostPrice, SellingPrice, Stock, LowStockThreshold, Size, Description, Durability, SurfaceType, IsWholesale) VALUES
('prod-fb-premier', 'Premier League Elite Football', 'Leather Footballs', 45.00, 25.00, 45.00, 120, 20, 'Size 5', 'Matchball of the English top-tier.', 'High-Grade', 'Grass', 1),
('prod-fb-champs', 'Champions Pro Star Ball', 'Leather Footballs', 50.00, 30.00, 50.00, 80, 15, 'Size 5', 'Star paneled thermal bonded matchball.', 'Extreme', 'Grass', 1),
('prod-fb-street', 'Street Asphalt Hardener', 'Rubber Footballs', 25.00, 12.00, 25.00, 250, 40, 'Size 4', 'Tough rubberized ball built for concrete.', 'Indestructible', 'Concrete/Street', 1),
('prod-fb-futsal', 'Futsal Low-Bounce Core', 'Futsal Footballs', 35.00, 18.00, 35.00, 60, 10, 'Standard', 'Low bounce heavy bladder ball for court action.', 'Premium', 'Indoor Court', 1),
('prod-fb-retro', 'Retro 1970 Leather Classic', 'Vintage Footballs', 60.00, 35.00, 60.00, 30, 5, 'Size 5', 'Classic brown cowhide stitched vintage collectable.', 'Medium', 'Display', 1);

-- ==========================================
-- 6. Seed Initial Testing Customer
-- ==========================================
INSERT INTO Customers (Id, Name, Phone, RegisteredBy, MarketingOfficerId) VALUES
('c-test777', 'Mogadishu FC Athletics', '+252-615-111111', 'u-admin100', 'u-admin100');

GO
print 'Seed operations completed successfully.';
GO
