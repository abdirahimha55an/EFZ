-- READ ONLY. Proposed payment terms for EXISTING orders (payment_terms IS NULL),
-- from evidence that already exists. Writes nothing. Run inside BEGIN READ ONLY.
--
-- Evidence = payments RECORDED in the order-creation flow: created_at within 10
-- minutes of the order's created_at, by record_payment() (id 'pay-' + 32 hex).
-- The payment DATE is ignored (it can be backdated).
--
--   proposal      rule
--   ------------  ------------------------------------------------------------
--   paid_at_sale  creation-flow payments >= the order total (total > 0)
--   credit        creation-flow payments <  the order total
--   REVIEW        any payment not created by record_payment() (imported from the
--                 old app: its creation time is the import time, not the sale);
--                 an invoice reduced by a delivery correction (the total changed
--                 after creation); a total of 0; an order converted from a website
--                 request (terms were never asked); payment_terms already set.
--
-- Only rows proposed paid_at_sale / credit may later be applied, each through
-- set_order_payment_terms(order, terms, '<evidence>') by a Super Admin (one
-- audit line per order). REVIEW rows are decided by the owner, one by one.
with o as (
  select o.id, o.status, o.total, o.order_date, o.created_at, o.payment_terms, o.legacy_reference_id,
         coalesce(sum(p.amount) filter (where p.created_at <= o.created_at + interval '10 minutes'
                                          and p.id ~ '^pay-[0-9a-f]{32}$'), 0)        as paid_in_creation_flow,
         count(p.id)                                                                    as payments,
         count(p.id) filter (where p.id !~ '^pay-[0-9a-f]{32}$')                       as imported_payments,
         coalesce(sum(p.amount), 0)                                                     as paid_total
    from public.orders o
    left join public.payments p on p.order_id = o.id
   group by o.id
)
select o.id, o.status, o.order_date, o.total, o.paid_in_creation_flow, o.payments, o.imported_payments, o.paid_total,
       case
         when o.payment_terms is not null then 'ALREADY SET: ' || o.payment_terms
         when o.total <= 0 then 'REVIEW: total is 0'
         when o.imported_payments > 0 then 'REVIEW: payments imported from the old app (sale-time evidence unknown)'
         when exists (select 1 from public.delivered_quantity_adjustments a where a.order_id = o.id and a.mode = 'reduce_invoice')
           then 'REVIEW: invoice reduced after creation'
         when exists (select 1 from public.order_requests r where r.converted_order_id = o.id)
           then 'REVIEW: converted from a website request'
         when o.paid_in_creation_flow >= o.total then 'paid_at_sale'
         else 'credit'
       end as proposal
  from o
 order by proposal, o.order_date, o.id;
