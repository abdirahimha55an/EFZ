-- =============================================================================
-- 27 - PREFLIGHT, READ-ONLY (plain SELECTs, changes nothing). Run it on Staging (through the established secure read-only procedure) BEFORE applying migration 27,
-- and on the local restore of the same backup. The two "definition" rows must show matches_pre27 = true on a database that has not had migration 27 applied.
-- The expected values were taken from a restore of Staging backup 20261017-165739Z; they have NOT been compared with the live Staging database. If a row shows
-- false, Staging has drifted from what migration 27 was written against: STOP, send the full definition for review, do not apply.
-- =============================================================================
select 'create_order' as definition,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) as md5_cr_stripped,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) = 'bad8d28eac60a8243e6bba614f6191a1' as matches_pre27,
       md5(replace(pg_get_functiondef('public.create_order(jsonb)'::regprocedure), chr(13), '')) = '265e9745acb9418787e6d8cebfb450af' as matches_27;
select 'convert_website_request',
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')),
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) = 'bc32b50df6f50e37e6759086a1f6dd1c',
       md5(replace(pg_get_functiondef('public.convert_website_request(uuid, jsonb)'::regprocedure), chr(13), '')) = 'fe992c8ab3edc37522d08e3e6eb41c9c';
select 'convert_order_request (not replaced; must stay as is)',
       md5(replace(pg_get_functiondef('public.convert_order_request(uuid, text)'::regprocedure), chr(13), '')),
       md5(replace(pg_get_functiondef('public.convert_order_request(uuid, text)'::regprocedure), chr(13), '')) = 'fc18ea5ee175c1448b399754c3baf6ef', null::boolean;
