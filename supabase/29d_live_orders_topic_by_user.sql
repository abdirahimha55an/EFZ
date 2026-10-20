-- =============================================================================
-- 29d. Live order updates: address the private topic by the customer's sign-in id instead of the Hub customer id
-- Why: the app knows its own sign-in id (auth.uid()) but not the Hub's internal customer id, and should not have to be told it. The topic is now
-- 'customer-orders:<auth user id>', one message per approved account of the order's customer. Receiving still requires an approved account AND a topic that
-- equals the caller's own id, so nobody can listen to anyone else's topic. Payload unchanged (order id, status, confirm/dispatch/delivery times; no money).
-- Run after 29b. ROLLBACK: supabase/rollback/29_dispatch_rollback.sql drops the trigger functions and policy entirely.
-- =============================================================================
begin;

create or replace function public.notify_customer_order_change()
returns trigger
language plpgsql security definer set search_path = public, realtime
as $f$
declare v_uid uuid;
begin
  begin
    for v_uid in
      select a.auth_user_id from public.customer_accounts a
       where a.customer_id = new.customer_id and a.status = 'approved' and a.deletion_requested_at is null
    loop
      perform realtime.send(
        jsonb_build_object('orderId', new.id, 'status', new.status::text, 'confirmedAt', new.confirmed_at, 'dispatchedAt', new.dispatched_at, 'deliveredAt', new.delivered_at),
        'order_changed', 'customer-orders:' || v_uid::text, true);
    end loop;
  exception when others then
    null;   -- a failed notification must never block an order write; the app also refetches on foreground and on a timer
  end;
  return null;
end
$f$;
revoke all on function public.notify_customer_order_change() from public, anon, authenticated;

drop policy if exists customer_orders_receive on realtime.messages;
create policy customer_orders_receive on realtime.messages for select to authenticated
  using (realtime.messages.extension = 'broadcast' and public._my_approved_customer_id() is not null and realtime.topic() = 'customer-orders:' || auth.uid()::text);

commit;
