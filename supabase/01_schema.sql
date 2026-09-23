-- ============================================================================
-- EFZ (Elite Football Zone) - Supabase / PostgreSQL Schema
-- File 1 of 5 : Enums, Tables, Indexes
-- ----------------------------------------------------------------------------
-- Run order:  01_schema.sql -> 02_functions.sql -> 03_rls.sql
--          -> 04_views.sql -> 05_seed.sql
--
-- Design decisions (agreed):
--   * Primary keys stay TEXT so existing IDs ('u-1', 'ORD-3567957',
--     'prod-1787244881309', 'cust-1787416286614') migrate unchanged.
--   * Supabase Auth owns credentials. profiles.auth_user_id -> auth.users(id).
--     No password column ever lives in this database.
--   * order_items and payments are real tables (no nested JSON).
--   * Commissions are a ledger, not a runtime calculation.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ============================================================================
-- 1. ENUM TYPES
-- ============================================================================

do $enums$
begin
  if not exists (select 1 from pg_type where typname = 'user_role') then
    create type public.user_role as enum (
      'Super Admin', 'Manager', 'Marketing Officer', 'Inventory Staff', 'Delivery Staff'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'user_status') then
    create type public.user_status as enum ('active', 'inactive');
  end if;

  if not exists (select 1 from pg_type where typname = 'customer_status') then
    create type public.customer_status as enum ('active', 'archived');
  end if;

  if not exists (select 1 from pg_type where typname = 'product_category') then
    create type public.product_category as enum ('Football', 'Futsal', 'Accessories');
  end if;

  if not exists (select 1 from pg_type where typname = 'order_status') then
    create type public.order_status as enum (
      'pending', 'confirmed', 'processing', 'delivered', 'cancelled'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'order_type') then
    create type public.order_type as enum ('regular', 'trial');
  end if;

  if not exists (select 1 from pg_type where typname = 'payment_status') then
    create type public.payment_status as enum (
      'unpaid', 'partial', 'paid', 'refunded', 'credit'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'stock_movement_type') then
    create type public.stock_movement_type as enum (
      'sale', 'manual_adjustment', 'correction', 'return', 'import'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'log_severity') then
    create type public.log_severity as enum ('INFO', 'WARNING', 'ERROR', 'CRITICAL');
  end if;

  if not exists (select 1 from pg_type where typname = 'log_category') then
    create type public.log_category as enum (
      'SECURITY', 'FINANCIAL', 'INVENTORY', 'CUSTOMER',
      'SYSTEM', 'AUTH', 'STORAGE', 'ORDER', 'PRODUCT'
    );
  end if;

  if not exists (select 1 from pg_type where typname = 'commission_status') then
    create type public.commission_status as enum ('pending', 'approved', 'paid', 'void');
  end if;

  if not exists (select 1 from pg_type where typname = 'notification_type') then
    create type public.notification_type as enum ('stock', 'order', 'system');
  end if;

  if not exists (select 1 from pg_type where typname = 'order_request_status') then
    create type public.order_request_status as enum ('new', 'contacted', 'converted', 'rejected');
  end if;
end
$enums$;

-- ============================================================================
-- 2. AUTH & USERS
-- ============================================================================

-- Staff accounts. Mirrors the AdminUser type in lib/types/index.ts.
create table if not exists public.profiles (
  id                        text primary key,
  auth_user_id              uuid unique references auth.users(id) on delete set null,
  name                      text not null,
  email                     text not null unique,
  phone                     text not null default '',
  avatar                    text not null default '',
  role                      public.user_role not null default 'Marketing Officer',
  status                    public.user_status not null default 'active',
  commission_percentage     numeric(5,2)  not null default 0
                              check (commission_percentage >= 0 and commission_percentage <= 100),
  earned_commission_total   numeric(14,2) not null default 0,
  pending_commission_total  numeric(14,2) not null default 0,
  paid_commission_total     numeric(14,2) not null default 0,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);

comment on table  public.profiles is 'Staff accounts. Credentials live in auth.users, never here.';
comment on column public.profiles.id is 'Legacy text id preserved from localStorage (e.g. u-1).';

-- Catalog of the permission codes in OFFICIAL_PERMISSIONS.
create table if not exists public.permissions (
  code        text primary key,
  label       text not null,
  category    text not null default 'General',
  sort_order  integer not null default 0
);

create table if not exists public.user_permissions (
  user_id          text not null references public.profiles(id)      on delete cascade,
  permission_code  text not null references public.permissions(code) on delete cascade,
  granted_at       timestamptz not null default now(),
  primary key (user_id, permission_code)
);

-- ============================================================================
-- 3. CRM
-- ============================================================================

create table if not exists public.customers (
  id                    text primary key,
  name                  text not null,
  email                 text not null default '',
  phone                 text not null default '',
  registered_by         text references public.profiles(id) on delete set null,
  marketing_officer_id  text references public.profiles(id) on delete set null,
  registered_on         date not null default current_date,
  notes                 text not null default '',
  status                public.customer_status not null default 'active',
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

comment on column public.customers.registered_on is 'Maps the legacy Customer.date field.';

-- ============================================================================
-- 4. CATALOG & INVENTORY
-- ============================================================================

create table if not exists public.products (
  id                   text primary key,
  name                 text not null,
  description          text not null default '',
  category             public.product_category not null default 'Football',
  size                 text not null default '',
  durability           text not null default '',
  surface_type         text not null default '',
  is_wholesale         boolean not null default true,
  cost_price           numeric(12,2) not null default 0  check (cost_price    >= 0),
  selling_price        numeric(12,2) not null default 0  check (selling_price >= 0),
  stock                integer       not null default 0  check (stock         >= 0),
  low_stock_threshold  integer       not null default 50 check (low_stock_threshold >= 0),
  image_url            text not null default '',
  is_active            boolean not null default true,
  -- Back-compat with the legacy Product.price alias. Always mirrors selling_price.
  price                numeric(12,2) generated always as (selling_price) stored,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create table if not exists public.stock_movements (
  id               text primary key,
  product_id       text not null references public.products(id) on delete cascade,
  product_name     text not null default '',
  type             public.stock_movement_type not null,
  quantity_change  integer not null,
  reason           text not null default '',
  created_by       text references public.profiles(id) on delete set null,
  created_at       timestamptz not null default now()
);

comment on column public.stock_movements.quantity_change is 'Negative for deductions (sale), positive for additions (import/return).';

-- ============================================================================
-- 5. SALES
-- ============================================================================

create table if not exists public.orders (
  id                   text primary key,
  customer_id          text references public.customers(id) on delete set null,
  customer_name        text not null default '',
  phone                text not null default '',
  marketing_officer_id text references public.profiles(id) on delete set null,
  status               public.order_status   not null default 'pending',
  payment_status       public.payment_status not null default 'unpaid',
  order_type           public.order_type     not null default 'regular',
  order_date           date not null default current_date,
  delivery_notes       text not null default '',
  total                numeric(14,2) not null default 0 check (total >= 0),
  cost                 numeric(14,2) not null default 0 check (cost  >= 0),
  gross_profit         numeric(14,2) not null default 0,
  amount_paid          numeric(14,2) not null default 0 check (amount_paid >= 0),
  outstanding_balance  numeric(14,2) not null default 0 check (outstanding_balance >= 0),
  commission_paid      boolean not null default false,
  legacy_order_ids     text[] not null default '{}',
  legacy_reference_id  text,
  created_by           text references public.profiles(id) on delete set null,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

comment on column public.orders.legacy_order_ids is 'Child order IDs merged into this parent order during the 2026-09-01 historical migration.';
comment on column public.orders.total is 'Maintained by trigger from order_items. Do not write directly.';

create table if not exists public.order_items (
  id                    text primary key,
  order_id              text not null references public.orders(id) on delete cascade,
  product_id            text references public.products(id)        on delete set null,
  product_name          text not null default 'Unknown Product',
  design_name           text not null default '',
  quantity              integer not null check (quantity > 0),
  standard_unit_price   numeric(12,2) not null default 0 check (standard_unit_price  >= 0),
  actual_unit_price     numeric(12,2) not null default 0 check (actual_unit_price    >= 0),
  historical_unit_cost  numeric(12,2) not null default 0 check (historical_unit_cost >= 0),
  line_revenue numeric(14,2) generated always as (actual_unit_price * quantity) stored,
  line_cost    numeric(14,2) generated always as (historical_unit_cost * quantity) stored,
  line_profit  numeric(14,2) generated always as
                 ((actual_unit_price - historical_unit_cost) * quantity) stored,
  created_at            timestamptz not null default now()
);

comment on column public.order_items.standard_unit_price  is 'List price at the time of sale.';
comment on column public.order_items.actual_unit_price    is 'Negotiated price actually charged.';
comment on column public.order_items.historical_unit_cost is 'Cost snapshot, frozen so later cost edits never rewrite history.';

create table if not exists public.payments (
  id              text primary key,
  order_id        text not null references public.orders(id) on delete cascade,
  amount          numeric(14,2) not null check (amount > 0),
  payment_date    date not null default current_date,
  payment_method  text not null default 'Cash',
  reference       text not null default '',
  notes           text not null default '',
  recorded_by     text references public.profiles(id) on delete set null,
  created_at      timestamptz not null default now()
);

-- Public order form submissions (app/order/page.tsx). Not yet a real order.
create table if not exists public.order_requests (
  id                  uuid primary key default gen_random_uuid(),
  customer_name       text not null,
  phone               text not null,
  organization        text not null default '',
  product_id          text references public.products(id) on delete set null,
  product_name        text not null default '',
  quantity            integer not null default 1 check (quantity > 0),
  delivery_location   text not null default '',
  notes               text not null default '',
  status              public.order_request_status not null default 'new',
  converted_order_id  text references public.orders(id)   on delete set null,
  handled_by          text references public.profiles(id) on delete set null,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ============================================================================
-- 6. FINANCE - commission ledger
-- ============================================================================

create table if not exists public.commission_payouts (
  id          uuid primary key default gen_random_uuid(),
  user_id     text not null references public.profiles(id) on delete cascade,
  amount      numeric(14,2) not null check (amount > 0),
  method      text not null default 'Cash',
  reference   text not null default '',
  notes       text not null default '',
  paid_by     text references public.profiles(id) on delete set null,
  paid_at     timestamptz not null default now(),
  created_at  timestamptz not null default now()
);

create table if not exists public.commissions (
  id           uuid primary key default gen_random_uuid(),
  order_id     text not null references public.orders(id)   on delete cascade,
  user_id      text not null references public.profiles(id) on delete cascade,
  rate         numeric(5,2)  not null default 0 check (rate >= 0 and rate <= 100),
  base_amount  numeric(14,2) not null default 0 check (base_amount >= 0),
  amount       numeric(14,2) not null default 0 check (amount >= 0),
  status       public.commission_status not null default 'pending',
  payout_id    uuid references public.commission_payouts(id) on delete set null,
  note         text not null default '',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (order_id, user_id)
);

comment on column public.commissions.base_amount is 'Order total at the moment the commission was earned.';
comment on column public.commissions.rate is 'Officer rate frozen at earning time, so later rate changes never rewrite history.';

-- ============================================================================
-- 7. SYSTEM - audit, diagnostics, settings
-- ============================================================================

create table if not exists public.system_logs (
  id           text primary key,
  occurred_at  timestamptz not null default now(),
  severity     public.log_severity not null default 'INFO',
  category     public.log_category not null default 'SYSTEM',
  message      text not null,
  user_id      text references public.profiles(id) on delete set null,
  username     text not null default '',
  target_id    text,
  metadata     jsonb not null default '{}'::jsonb
);

create table if not exists public.system_issues (
  id                    text primary key,
  title                 text not null,
  severity              public.log_severity not null default 'WARNING',
  source                text not null default 'system',
  affected_entity_type  text,
  affected_entity_id    text,
  linked_system         text,
  impact                text,
  affected_count        integer not null default 1,
  explanation           text not null default '',
  recommended_action    text not null default '',
  repairable            boolean not null default false,
  resolved_at           timestamptz,
  created_at            timestamptz not null default now(),
  last_detected_at      timestamptz not null default now()
);

create table if not exists public.notifications (
  id          text primary key,
  title       text not null,
  message     text not null default '',
  type        public.notification_type not null default 'system',
  user_id     text references public.profiles(id) on delete cascade,
  read        boolean not null default false,
  created_at  timestamptz not null default now()
);

comment on column public.notifications.user_id is 'NULL means the notification is broadcast to all staff.';

-- Single-row settings table. The id check pins it to exactly one row.
create table if not exists public.settings (
  id                           boolean primary key default true check (id),
  business_name                text not null default 'Elite Football Zone',
  short_name                   text not null default 'EFZ',
  logo                         text not null default '',
  favicon                      text not null default '',
  whatsapp_number              text not null default '',
  contact_email                text not null default '',
  default_low_stock_threshold  integer not null default 50,
  currency_symbol              text not null default '$',
  theme                        text not null default 'light' check (theme in ('light', 'dark')),
  primary_color                text not null default '#0F172A',
  secondary_color              text not null default '#00E676',
  updated_by                   text references public.profiles(id) on delete set null,
  updated_at                   timestamptz not null default now()
);

create table if not exists public.backups (
  id             uuid primary key default gen_random_uuid(),
  label          text not null default '',
  storage_path   text,
  payload        jsonb,
  record_counts  jsonb not null default '{}'::jsonb,
  size_bytes     bigint not null default 0,
  created_by     text references public.profiles(id) on delete set null,
  created_at     timestamptz not null default now()
);

comment on column public.backups.payload is 'Inline snapshot. Leave NULL and use storage_path once snapshots outgrow a row.';

-- Public marketing content (replaces MOCK_TESTIMONIALS in lib/data.ts).
create table if not exists public.testimonials (
  id            text primary key,
  name          text not null,
  role          text not null default '',
  content       text not null,
  is_published  boolean not null default true,
  sort_order    integer not null default 0,
  created_at    timestamptz not null default now()
);

-- ============================================================================
-- 8. INDEXES
-- ============================================================================

create index if not exists idx_profiles_role            on public.profiles(role);
create index if not exists idx_profiles_status          on public.profiles(status);
create index if not exists idx_profiles_auth_user       on public.profiles(auth_user_id);

create index if not exists idx_user_permissions_user    on public.user_permissions(user_id);

create index if not exists idx_customers_officer        on public.customers(marketing_officer_id);
create index if not exists idx_customers_registered_by  on public.customers(registered_by);
create index if not exists idx_customers_status         on public.customers(status);
create index if not exists idx_customers_phone          on public.customers(phone);

create index if not exists idx_products_category        on public.products(category);
create index if not exists idx_products_active          on public.products(is_active);
create index if not exists idx_products_low_stock       on public.products(stock) where is_active;

create index if not exists idx_stock_movements_product  on public.stock_movements(product_id);
create index if not exists idx_stock_movements_created  on public.stock_movements(created_at desc);

create index if not exists idx_orders_customer          on public.orders(customer_id);
create index if not exists idx_orders_officer           on public.orders(marketing_officer_id);
create index if not exists idx_orders_status            on public.orders(status);
create index if not exists idx_orders_payment_status    on public.orders(payment_status);
create index if not exists idx_orders_date              on public.orders(order_date desc);

create index if not exists idx_order_items_order        on public.order_items(order_id);
create index if not exists idx_order_items_product      on public.order_items(product_id);

create index if not exists idx_payments_order           on public.payments(order_id);
create index if not exists idx_payments_date            on public.payments(payment_date desc);

create index if not exists idx_order_requests_status    on public.order_requests(status);
create index if not exists idx_order_requests_created   on public.order_requests(created_at desc);

create index if not exists idx_commissions_user         on public.commissions(user_id);
create index if not exists idx_commissions_status       on public.commissions(status);
create index if not exists idx_commissions_payout       on public.commissions(payout_id);
create index if not exists idx_commission_payouts_user  on public.commission_payouts(user_id);

create index if not exists idx_system_logs_occurred     on public.system_logs(occurred_at desc);
create index if not exists idx_system_logs_category     on public.system_logs(category);
create index if not exists idx_system_logs_severity     on public.system_logs(severity);
create index if not exists idx_system_logs_user         on public.system_logs(user_id);

create index if not exists idx_system_issues_severity   on public.system_issues(severity);
create index if not exists idx_system_issues_open       on public.system_issues(last_detected_at desc)
  where resolved_at is null;

create index if not exists idx_notifications_user       on public.notifications(user_id, read);
