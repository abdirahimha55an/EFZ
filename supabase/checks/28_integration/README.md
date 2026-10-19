# Migration 28 - Staging integration tests (T1-T17)

STAGING ONLY (`adjjamiqwboawqedaapi`). Run with the Supabase CLI logged in. Nothing here touches Production.

| Group | Covers |
|---|---|
| `g1_pricing` | T1 list price, T1b new customer, T2 product agreement, T5/T5b review-required (pending agreement blocks, then verified) |
| `g2_designs` | T3 design id / name / removed-design name, T4/T6 several designs of one product, T4b design + no-design lines, T7 joint stock, T8 duplicate / invalid designs |
| `g3_overrides` | T9 missing / short / blank reason, T10 valid override + audit, T10b exact agreed price / higher price / list customer, T11 below-cost rules, T11b approved below-cost agreement, T11c Clearance list < cost |
| `g4_protections` | T12 duplicate / out-of-state conversion, T13 who may convert, T14 old payload, T15 totals + delivery + payment + stock + commission vs a directly created control order |
| `g5_app_e2e` | the customer-app path: real RPC submit as an approved account -> confirm -> the Hub's own query -> convert |
| `g6_rollback` | T17: the real rollback text and the real migration text applied back and forth, plus both guards (all rolled back) |
| `rehearse_cancel` | Rolled-back rehearsal of the Manager cancellation of the concurrency-test order `ORD-4877625` (refuses to run unless that order is still pending). Run with `./run.sh rehearse_cancel`. |
| `concurrency.sh` | T12 concurrent: the ONLY test that commits (1 customer, 1 request, 1 order, all `TEST-28`) |

## How it is made safe
* `run.sh` pins the Staging project ref; every file asserts the synthetic Staging staff exist before doing anything.
* Each group is one batch that ends with `raise exception 'T28RESULT:<json>'`, so everything is rolled back; the results travel out in the error text. Cases that would compete for the same stock run in nested blocks that roll back individually.
* Real call paths: staff and customer-app sessions are impersonated (`request.jwt.claims` + `set local role authenticated`), requests are created through the public form RPC, agreements through `create_price_agreement`.

## Known limits
* Every order made in one transaction shares one `now()`. "Which order was a customer's first" (the first-order bonus holder) then ties and falls to the lower random order id, converted or not. T15 therefore compares a converted order with a control order of a DIFFERENT customer.
* `concurrency.sh` starts parallel CLI sessions; two CLI logins started at the same instant can collide on their temporary login role (a CLI error before any SQL runs). Start the contenders a few seconds apart.
* `u-stg-nologin` has no login, so it cannot be exercised.
* These scripts test the database. The Hub dialog is covered by `lib/requestConversion.test.ts`, not here.
