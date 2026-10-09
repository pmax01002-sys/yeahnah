-- A nightly record of the slash economy, to set slashtax's targets from real
-- numbers before any tax exists. It only reads: nobody's slashes change.
-- One row per UK day in economy_days, written just after midnight for the
-- day before, and filled in for every earlier day the first time it runs.
-- Read it in the Supabase table editor; the app never shows it.
--
-- Settings it reads, in app_config (whole numbers, so 1.0 is stored as 100):
--   slashtax_allowance      20   slashes nobody would be taxed on
--   virality_spread_target  100  answered sends per active person a week = 1.0
--   virality_growth_target  10   link joins per active person a week = 0.10
--   virality_spread_weight  70   spread's share of v, in %; growth gets the rest
--   virality_min_people     10   fewer weekly active people than this: use the manual v
--   virality_manual         100  the v used then (1.00)
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('slashtax_allowance', 20),
  ('virality_spread_target', 100),
  ('virality_growth_target', 10),
  ('virality_spread_weight', 70),
  ('virality_min_people', 10),
  ('virality_manual', 100)
on conflict (key) do nothing;

create table if not exists public.economy_days (
  day date primary key,                -- the UK day this row describes
  weekly_active int not null,          -- established people who answered in the 7 days to this day's end
  answered_sends int not null,         -- sent or passed-on questions answered in time this day
  link_joins int not null,             -- new people this day who came in through a group or question link
  minted int not null,                 -- slashes created this day (sign-up grants, answer rewards)
  spent int not null,                  -- slashes spent this day (sends, questions, Future unlocks)
  total_held bigint not null,          -- every balance added up at this day's end
  median_balance numeric not null,
  p90_balance numeric not null,        -- 90% of people hold this many or fewer
  over_allowance int not null,         -- people holding more than slashtax_allowance
  spread numeric not null,             -- answered sends per weekly active person, last 7 days
  growth numeric not null,             -- link joins per weekly active person, last 7 days
  v numeric not null,                  -- virality, 1.0 = target pace
  v_is_manual boolean not null,        -- too few people, so v is virality_manual
  recorded_at timestamptz not null default now()
);
alter table public.economy_days enable row level security;  -- no policies: only the table editor reads it

create or replace function public.record_economy_day(p_day date) returns void
language plpgsql security definer set search_path = '' as $$
declare
  d0 timestamptz := p_day::timestamp at time zone 'Europe/London';
  d1 timestamptz := (p_day + 1)::timestamp at time zone 'Europe/London';
  w0 timestamptz := (p_day - 6)::timestamp at time zone 'Europe/London';
  active int; sends int; joins int; sends7 int; joins7 int; s numeric; g numeric; vv numeric; manual boolean;
begin
  -- Established = an account at least a day old with 3 or more answers by then.
  select count(*) into active from public.profiles p
   where p.created_at < d1 - interval '1 day'
     and (select count(*) from public.statements s where s.user_id = p.id and s.created_at < d1) >= 3
     and exists (select 1 from public.statements s where s.user_id = p.id and s.created_at >= w0 and s.created_at < d1);

  select count(*) filter (where answered_at >= d0), count(*) into sends, sends7
    from public.challenges
   where answered_at >= w0 and answered_at < d1 and answered_at <= expires_at;

  -- Came in through a link = joined a group or opened a question link within
  -- an hour of making their profile.
  select count(*) filter (where p.created_at >= d0), count(*) into joins, joins7
    from public.profiles p
   where p.created_at >= w0 and p.created_at < d1
     and (exists (select 1 from public.group_members m where m.user_id = p.id
                   and m.joined_at < p.created_at + interval '1 hour')
          or exists (select 1 from public.question_link_opens o where o.user_id = p.id
                      and o.opened_at < p.created_at + interval '1 hour'));

  manual := active < public.cfg('virality_min_people');
  s := case when active > 0 then sends7::numeric / active else 0 end;
  g := case when active > 0 then joins7::numeric / active else 0 end;
  vv := case when manual then public.cfg('virality_manual') / 100.0
             else public.cfg('virality_spread_weight') / 100.0 * s / (public.cfg('virality_spread_target') / 100.0)
                + (1 - public.cfg('virality_spread_weight') / 100.0) * g / (public.cfg('virality_growth_target') / 100.0) end;

  insert into public.economy_days (day, weekly_active, answered_sends, link_joins, minted, spent, total_held,
                                   median_balance, p90_balance, over_allowance, spread, growth, v, v_is_manual)
  select p_day, active, sends, joins,
         (select coalesce(sum(amount), 0) from public.credit_ledger where amount > 0 and created_at >= d0 and created_at < d1),
         (select coalesce(-sum(amount), 0) from public.credit_ledger where amount < 0 and created_at >= d0 and created_at < d1),
         coalesce(sum(b.bal), 0),
         coalesce(percentile_cont(0.5) within group (order by b.bal), 0),
         coalesce(percentile_cont(0.9) within group (order by b.bal), 0),
         count(*) filter (where b.bal > public.cfg('slashtax_allowance')),
         round(s, 3), round(g, 3), round(vv, 2), manual
    from (select p.id, coalesce((select sum(amount) from public.credit_ledger c
                                  where c.user_id = p.id and c.created_at < d1), 0) as bal
            from public.profiles p where p.created_at < d1) b
  on conflict (day) do update set
    weekly_active = excluded.weekly_active, answered_sends = excluded.answered_sends,
    link_joins = excluded.link_joins, minted = excluded.minted, spent = excluded.spent,
    total_held = excluded.total_held, median_balance = excluded.median_balance,
    p90_balance = excluded.p90_balance, over_allowance = excluded.over_allowance,
    spread = excluded.spread, growth = excluded.growth, v = excluded.v,
    v_is_manual = excluded.v_is_manual, recorded_at = now();
end $$;

-- Records every finished day that has no row yet, back to the first profile.
create or replace function public.record_economy_days() returns int
language plpgsql security definer set search_path = '' as $$
declare d date; n int := 0;
begin
  for d in
    select g::date from generate_series(
      (select min(created_at at time zone 'Europe/London')::date from public.profiles),
      public.today_uk() - 1, interval '1 day') g
    where not exists (select 1 from public.economy_days e where e.day = g::date)
  loop
    perform public.record_economy_day(d);
    n := n + 1;
  end loop;
  return n;
end $$;

revoke execute on function public.record_economy_day(date), public.record_economy_days() from public, anon, authenticated;

-- Every hour, so the row lands just after UK midnight whatever the clocks do.
do $$
begin
  perform cron.schedule('record-economy', '20 * * * *', 'select public.record_economy_days()');
exception when others then
  raise notice 'pg_cron not available: run record_economy_days() yourself each day';
end $$;

select public.record_economy_days();
