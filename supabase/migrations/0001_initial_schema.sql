 -- ============================================================
  -- LedgerGuard
  -- ============================================================

  -- 1. ENUMS -----------------------------------------------------
  create type public.account_type as enum ('checking', 'savings', 'credit_card');
  create type public.txn_type     as enum ('purchase', 'deposit', 'transfer', 'fee', 'refund');
  create type public.txn_status   as enum ('pending', 'posted', 'reversed');

  -- 2. TABLES ----------------------------------------------------
  create table public.profiles (
    id         uuid primary key references auth.users (id) on delete cascade,
    full_name  text,
    created_at timestamptz not null default now()
  );

  create table public.accounts (
    id         uuid primary key default gen_random_uuid(),
    -- restrict: a user with financial records cannot be silently deleted
    user_id    uuid not null references public.profiles (id) on delete restrict,
    name       text not null,
    type       public.account_type not null,
    currency   char(3) not null check (currency ~ '^[A-Z]{3}$'),
    created_at timestamptz not null default now(),
    -- target for the composite FK from transactions
    unique (id, user_id, currency)
  );

  create table public.categories (
    id   smallint generated always as identity primary key,
    name text not null unique
  );

  create table public.transactions (
  id            uuid primary key default gen_random_uuid(),
  account_id    uuid not null,
  user_id       uuid not null,
  amount_cents  bigint not null check (amount_cents <> 0),  -- signed: negative = money out
  currency      char(3) not null,
  type          public.txn_type not null,
  status        public.txn_status not null default 'posted',
  merchant_name text,
  category_id   smallint references public.categories (id),
  description   text,
  occurred_at   timestamptz not null,
  created_at    timestamptz not null default now(),

  -- DB guarantees user_id AND currency match the owning account
  foreign key (account_id, user_id, currency)
    references public.accounts (id, user_id, currency),

  -- sign must match the transaction type
  check (
    (type in ('purchase', 'fee') and amount_cents < 0)
    or (type in ('deposit', 'refund') and amount_cents > 0)
    or type = 'transfer'
  )
);

create table public.audit_log (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users (id) on delete set null,
  request_id uuid,
  tool_name  text not null,
  args       jsonb not null default '{}'::jsonb,   -- must be redacted by the caller
  outcome    text not null check (outcome in ('ok', 'denied', 'error')),
  latency_ms integer check (latency_ms >= 0),
  created_at timestamptz not null default now()
);

-- 3. INDEXES ---------------------------------------------------
create index accounts_user_id_idx          on public.accounts (user_id);
create index transactions_account_time_idx on public.transactions (account_id, occurred_at desc);
create index transactions_user_time_idx    on public.transactions (user_id, occurred_at desc);
create index transactions_category_idx     on public.transactions (category_id);
create index audit_log_user_time_idx       on public.audit_log (user_id, created_at desc);

-- 4. ROW LEVEL SECURITY ----------------------------------------
alter table public.profiles     enable row level security;
alter table public.accounts     enable row level security;
alter table public.categories   enable row level security;
alter table public.transactions enable row level security;
alter table public.audit_log    enable row level security;  -- no policies = no direct access

create policy profiles_select_own on public.profiles
  for select to authenticated
  using (id = (select auth.uid()));

create policy accounts_select_own on public.accounts
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy transactions_select_own on public.transactions
  for select to authenticated
  using (user_id = (select auth.uid()));

create policy categories_select_all on public.categories
  for select to authenticated
  using (true);

-- 5. GRANTS (least privilege: read-only, nothing for anon) -----
revoke all on public.profiles, public.accounts, public.categories,
              public.transactions, public.audit_log
  from anon, authenticated;

grant select on public.profiles, public.accounts, public.categories,
                public.transactions
  to authenticated;

-- 6. BALANCE VIEW (computed from the ledger, RLS still applies) -
create view public.v_account_balances
with (security_invoker = true) as
select
  a.id       as account_id,
  a.user_id,
  a.name,
  a.currency,
  coalesce(sum(t.amount_cents) filter (where t.status = 'posted'), 0)::bigint as balance_cents
from public.accounts a
left join public.transactions t on t.account_id = a.id
group by a.id, a.user_id, a.name, a.currency;

revoke all on public.v_account_balances from anon, authenticated;
grant select on public.v_account_balances to authenticated;

-- 7. AUDIT FUNCTION (insert-only path for the agent) -----------
create or replace function public.log_tool_call(
  p_request_id uuid,
  p_tool_name  text,
  p_args       jsonb,
  p_outcome    text,
  p_latency_ms integer
)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_log (user_id, request_id, tool_name, args, outcome, latency_ms)
  values ((select auth.uid()), p_request_id, p_tool_name,
          coalesce(p_args, '{}'::jsonb), p_outcome, p_latency_ms);
$$;

revoke all on function public.log_tool_call(uuid, text, jsonb, text, integer)
  from public, anon;
grant execute on function public.log_tool_call(uuid, text, jsonb, text, integer)
  to authenticated;


-- 8. AUTO-CREATE PROFILE ON SIGNUP -----------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, new.raw_user_meta_data ->> 'full_name');
  return new;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();