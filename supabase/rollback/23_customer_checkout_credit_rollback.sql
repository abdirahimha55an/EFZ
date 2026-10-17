-- =============================================================================
-- ROLLBACK of migration 23 (customer checkout, finance, credit). Staging first; Production only with the owner's explicit approval.
-- Removes only objects created by 23. Orders, order lines and payments created through the customer channel are ordinary financial records
-- and are NOT touched here: the tables that link them (customer_checkouts, customer_credit_orders) are dropped, so first make sure no
-- checkout or credit order must be kept as evidence (export them), or the link between those orders and their checkout is lost.
-- =============================================================================
begin;
set local lock_timeout = '30s';

drop function if exists public.resolve_customer_checkout(uuid, text);
drop function if exists public.list_checkouts_for_review();
drop function if exists public.suspend_customer_credit(text, text);
drop function if exists public.set_customer_credit(text, numeric, integer, text, text);
drop function if exists public.credit_overview();
drop function if exists public.set_credit_policy(boolean, integer, numeric, boolean, integer, text);
drop function if exists public.get_credit_policy();
drop function if exists public.set_payment_method(text, text, text, boolean, text);
drop function if exists public.list_payment_methods();
drop function if exists public.finance_audit(text, text, jsonb);
drop function if exists public._require_finance_admin();
drop function if exists public.expire_stale_checkouts();
drop function if exists public.finalize_customer_checkout(uuid, text, text, text, numeric, text, text, boolean);
drop function if exists public.my_finance();
drop function if exists public.customer_place_credit_order(jsonb);
drop function if exists public.customer_cancel_checkout(uuid);
drop function if exists public.my_checkout_status(uuid);
drop function if exists public.customer_start_checkout(jsonb);
drop function if exists public.customer_credit_status();
drop function if exists public.customer_payment_methods();
drop function if exists public.customer_price_preview(jsonb);
drop function if exists public._customer_credit_summary(text);
drop function if exists public._customer_credit_eligibility(text);
drop function if exists public._record_online_payment(text, numeric, text, text, text);
drop function if exists public._customer_create_order(text, jsonb, text, text, text, text);
drop function if exists public._customer_price_cart(jsonb);

drop table if exists public.customer_credit_orders;
drop table if exists public.customer_credit_accounts;
drop table if exists public.credit_policy;
drop table if exists public.payment_checkout_events;
drop table if exists public.customer_checkouts;
drop table if exists public.payment_methods;

drop function if exists public.guard_payment_event_update();
drop function if exists public.guard_no_delete_finance();

commit;
