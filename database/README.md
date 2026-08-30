# EFZ SQL Server Database Schema Preparation Layer

This directory contains pure, native Microsoft SQL Server T-SQL scripts to prepare the EFZ relational database.

> [!IMPORTANT]
> **T-SQL Only:** All files use Microsoft SQL Server dialect (Transact-SQL). Do not execute these on PostgreSQL or Supabase instances.

## Directory Structure

```
database/
├── README.md                 # This setup and execution guide
├── football_schema.sql       # Master unified script for quick execution
├── tables/
│   └── 01_tables.sql         # Base database tables with strict constraints
├── functions/
│   └── 02_functions.sql      # T-SQL Business Logic Functions
├── views/
│   └── 03_views.sql          # T-SQL Aggregation Views
├── procedures/
│   └── 04_procedures.sql     # T-SQL Stored Procedures for state changes
└── seed/
    └── 05_seed.sql           # Initial seed data for system testing
```

## SQL Script Execution Order

To prevent relational integrity (Foreign Key) violations, always execute the scripts in the following exact order inside **SQL Server Management Studio (SSMS)** or **Azure Data Studio**:

1. **`tables/01_tables.sql`** — Deletes existing tables in reverse dependency order and sets up the structural tables, keys, and indexes.
2. **`functions/02_functions.sql`** — Compiles the business calculations used inside views and procedures.
3. **`views/03_views.sql`** — Renders the aggregated analytical reporting layers.
4. **`procedures/04_procedures.sql`** — Compiles stored procedures for creation, updates, and integrity scans.
5. **`seed/05_seed.sql`** — Seeds the database with standard administrative privileges, mock products, and diagnostic issues.

---

## Database Connection Setup Quickstart

1. Open **SSMS** and connect to your SQL Server instance (e.g., `localhost` or `sa`).
2. Run the command:
   ```sql
   CREATE DATABASE football;
   GO
   USE football;
   GO
   ```
3. Open the unified master script **`football_schema.sql`** or execute the scripts `01` through `05` in sequential order.
