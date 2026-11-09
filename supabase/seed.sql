-- ============================================================
-- LedgerGuard: seed data (FAKE DATA ONLY, development use)
-- Safe to re-run: every insert is idempotent.
--
-- Users (password for both: LedgerGuard-Dev-1!  <- dev only, never reuse)
--   alice@example.com   11111111-1111-4111-8111-111111111111
--   bob@example.com     22222222-2222-4222-8222-222222222222
--
-- Expected posted balances (cents), useful for tests:
--   Alice checking     271706
--   Alice savings       50125
--   Alice credit card   -3660
--   Bob   checking     309996
--   Bob   savings     1000000
-- ============================================================

-- 1. AUTH USERS ------------------------------------------------
-- The on_auth_user_created trigger creates the matching public.profiles rows.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
)
values
  ('00000000-0000-0000-0000-000000000000',
   '11111111-1111-4111-8111-111111111111', 'authenticated', 'authenticated',
   'alice@example.com', extensions.crypt('LedgerGuard-Dev-1!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   jsonb_build_object('full_name', 'Alice Johnson'), now(), now(), '', '', '', ''),
  ('00000000-0000-0000-0000-000000000000',
   '22222222-2222-4222-8222-222222222222', 'authenticated', 'authenticated',
   'bob@example.com', extensions.crypt('LedgerGuard-Dev-1!', extensions.gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}',
   jsonb_build_object('full_name', 'Bob Martinez'), now(), now(), '', '', '', '')
on conflict (id) do nothing;

-- Identities let these users sign in with email + password
insert into auth.identities (
  id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at
)
select
  gen_random_uuid(), u.id, u.id::text,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true),
  'email', now(), now(), now()
from auth.users u
where u.id in ('11111111-1111-4111-8111-111111111111',
               '22222222-2222-4222-8222-222222222222')
  and not exists (
    select 1 from auth.identities i where i.user_id = u.id and i.provider = 'email'
  );

-- 2. CATEGORIES ------------------------------------------------
insert into public.categories (name) values
  ('Groceries'), ('Dining'), ('Transport'), ('Entertainment'), ('Shopping'),
  ('Travel'), ('Housing'), ('Income'), ('Fees'), ('Transfers')
on conflict (name) do nothing;

-- 3. ACCOUNTS --------------------------------------------------
insert into public.accounts (id, user_id, name, type, currency) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000001', '11111111-1111-4111-8111-111111111111', 'Alice Main Checking', 'checking',    'USD'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000002', '11111111-1111-4111-8111-111111111111', 'Alice Savings',       'savings',     'USD'),
  ('aaaaaaaa-aaaa-4aaa-8aaa-000000000003', '11111111-1111-4111-8111-111111111111', 'Alice Credit Card',   'credit_card', 'USD'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000001', '22222222-2222-4222-8222-222222222222', 'Bob Main Checking',   'checking',    'USD'),
  ('bbbbbbbb-bbbb-4bbb-8bbb-000000000002', '22222222-2222-4222-8222-222222222222', 'Bob Savings',         'savings',     'USD')
on conflict (id) do nothing;

-- 4. TRANSACTIONS ----------------------------------------------
-- user_id and currency come from the account, so the composite FK always holds.
-- Ids are deterministic (md5 of the key) so re-running does nothing.
-- Sign rules: purchase/fee negative, deposit/refund positive, transfer either.
insert into public.transactions (
  id, account_id, user_id, amount_cents, currency, type, status,
  merchant_name, category_id, description, occurred_at
)
select
  md5(v.key)::uuid, a.id, a.user_id, v.amount_cents, a.currency,
  v.type::public.txn_type, v.status::public.txn_status,
  v.merchant, c.id, v.descr, now() - v.days_ago * interval '1 day'
from (values
  -- key,            account_id,                              cents,   type,       status,     merchant,             category,        description,                days_ago
  -- Alice checking
  ('alice-chk-01', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',  350000, 'deposit',  'posted',   'Acme Corp',          'Income',        'Monthly salary',           28),
  ('alice-chk-02', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -8420, 'purchase', 'posted',   'Whole Foods',        'Groceries',     'Weekly groceries',         12),
  ('alice-chk-03', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',  -50000, 'transfer', 'posted',   null,                 'Transfers',     'To savings',               10),
  ('alice-chk-04', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -1599, 'purchase', 'posted',   'Netflix',            'Entertainment', 'Monthly subscription',      9),
  ('alice-chk-05', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -7999, 'purchase', 'reversed', 'Best Buy',           'Shopping',      'Headphones (cancelled)',    7),
  ('alice-chk-06', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -4500, 'purchase', 'posted',   'Shell',              'Transport',     'Fuel',                      6),
  ('alice-chk-07', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',    -500, 'fee',      'posted',   'LedgerGuard Bank',   'Fees',          'Monthly maintenance fee',   5),
  ('alice-chk-08', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',    2999, 'refund',   'posted',   'Amazon',             'Shopping',      'Returned item',             4),
  ('alice-chk-09', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -3275, 'purchase', 'posted',   'Starbucks',          'Dining',        'Coffee with team',          3),
  ('alice-chk-10', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',  -12999, 'purchase', 'posted',   'Amazon',             'Shopping',      'Desk lamp',                 1),
  ('alice-chk-11', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000001',   -2350, 'purchase', 'pending',  'Uber Eats',          'Dining',        'Dinner delivery',           0),
  -- Alice savings
  ('alice-sav-01', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000002',   50000, 'transfer', 'posted',   null,                 'Transfers',     'From checking',            10),
  ('alice-sav-02', 'aaaaaaaa-aaaa-4aaa-8aaa-000000000002',     125, 'deposit',  'posted',   'LedgerGuard Bank',   'Income',        'Interest',                  2),
  -- Alice credit card
  ('alice-cc-01',  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',   -6450, 'purchase', 'posted',   'Delta Air Lines',    'Travel',        'Flight booking',           14),
  ('alice-cc-02',  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',   -2210, 'purchase', 'posted',   'Trader Joe''s',      'Groceries',     'Groceries',                 8),
  ('alice-cc-03',  'aaaaaaaa-aaaa-4aaa-8aaa-000000000003',    5000, 'transfer', 'posted',   null,                 'Transfers',     'Card payment',              5),
  -- Bob checking
  ('bob-chk-01',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',  420000, 'deposit',  'posted',   'Globex Payroll',     'Income',        'Monthly salary',           27),
  ('bob-chk-02',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',  -95000, 'purchase', 'posted',   'Sunrise Properties', 'Housing',       'Monthly rent',             25),
  ('bob-chk-03',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',   -6710, 'purchase', 'posted',   'Costco',             'Groceries',     'Bulk groceries',           11),
  ('bob-chk-04',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',   -1099, 'purchase', 'posted',   'Spotify',            'Entertainment', 'Monthly subscription',      8),
  ('bob-chk-05',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',   -5320, 'purchase', 'posted',   'Chevron',            'Transport',     'Fuel',                      4),
  ('bob-chk-06',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000001',   -1875, 'purchase', 'posted',   'Chipotle',           'Dining',        'Lunch',                     2),
  -- Bob savings
  ('bob-sav-01',   'bbbbbbbb-bbbb-4bbb-8bbb-000000000002', 1000000, 'deposit',  'posted',   'LedgerGuard Bank',   'Income',        'Initial deposit',          60)
) as v(key, account_id, amount_cents, type, status, merchant, category, descr, days_ago)
join public.accounts a on a.id = v.account_id::uuid
left join public.categories c on c.name = v.category
on conflict (id) do nothing;
