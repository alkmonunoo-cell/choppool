-- ChopPool update 52: business costs for the income statement (owner only)
-- Each cost is expensed now, spread over some months (prepaid), or an asset depreciated straight-line monthly.
-- Safe to run more than once.

create table if not exists business_costs (
  id uuid primary key default gen_random_uuid(),
  cost_date date not null,
  category text not null check (char_length(category) between 2 and 60),
  description text not null default '' check (char_length(description) <= 200),
  amount numeric not null check (amount > 0 and amount < 100000000),
  paid_from text not null default 'momo' check (paid_from in ('momo', 'bank', 'cash', 'owner')),
  treatment text not null default 'expense' check (treatment in ('expense', 'spread', 'asset')),
  months int check (months is null or months between 1 and 480),          -- spread: months to spread over; asset: useful life in months
  residual numeric not null default 0 check (residual >= 0),               -- asset: value left at the end of its life
  created_by text not null default coalesce(auth.jwt() ->> 'email', 'system'),
  created_at timestamptz not null default now(),
  constraint business_costs_months_chk check (treatment = 'expense' or months is not null),
  constraint business_costs_residual_chk check (residual < amount)
);
create index if not exists business_costs_date_idx on business_costs (cost_date);
alter table business_costs enable row level security;
drop policy if exists "owner manages costs" on business_costs;
create policy "owner manages costs" on business_costs for all to authenticated using (is_super()) with check (is_super());
revoke all on business_costs from anon;
grant select, insert, update, delete on business_costs to authenticated;
