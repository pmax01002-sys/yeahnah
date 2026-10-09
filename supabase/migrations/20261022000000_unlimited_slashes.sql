-- Unlimited slashes for chosen accounts: the owner's own, to try everything
-- without running out. Spending from one of these accounts still happens and
-- is still written to credit_ledger, but as 0, so the balance never goes down.
-- A one-off top-up to 1000 makes every "can you afford it" check pass, and the
-- app shows the balance as ∞.
--
-- Add an account in the SQL Editor:   select public.give_unlimited_slashes('handle');
-- Take it away again:                 delete from public.unlimited_slashes where user_id = (select id from public.profiles where handle = 'handle');
--
-- The top-up is a credit_ledger row with the reason 'unlimited'. Economy
-- numbers should leave these accounts out (see public.has_unlimited_slashes).
--
-- Safe to run twice.

create table if not exists public.unlimited_slashes (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.unlimited_slashes enable row level security;  -- no policies: only the table editor reads it
revoke all on public.unlimited_slashes from anon, authenticated;

create or replace function public.has_unlimited_slashes(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.unlimited_slashes where user_id = p_user)
$$;

-- Spends from an unlimited account are kept, at 0, so their history still shows.
create or replace function public.unlimited_spend() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.amount < 0 and exists (select 1 from public.unlimited_slashes where user_id = new.user_id) then
    new.amount := 0;
  end if;
  return new;
end $$;
drop trigger if exists unlimited_spend on public.credit_ledger;
create trigger unlimited_spend before insert on public.credit_ledger
  for each row execute function public.unlimited_spend();

create or replace function public.give_unlimited_slashes(p_handle text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid; bal int;
begin
  select id into uid from public.profiles where handle = lower(p_handle);
  if uid is null then raise exception 'No one with the handle %', p_handle; end if;
  insert into public.unlimited_slashes (user_id) values (uid) on conflict do nothing;
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < 1000 then
    insert into public.credit_ledger (user_id, amount, reason) values (uid, 1000 - bal, 'unlimited');
  end if;
end $$;
revoke execute on function public.give_unlimited_slashes(text), public.has_unlimited_slashes(uuid),
  public.unlimited_spend() from public, anon, authenticated;

-- Max's own account.
do $$ begin
  if exists (select 1 from public.profiles where handle = 'harley') then perform public.give_unlimited_slashes('harley'); end if;
end $$;

-- my_profile says whether you have unlimited slashes, so the app can show ∞.
create or replace function public.my_profile() returns json
language sql stable security definer set search_path = '' as $$
  with used as (select public.answers_used_today(auth.uid()) as u)
  select json_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'avatar', p.avatar,
    'is_adult', public.is_adult(p.id),
    'sensitive_opt_in', p.sensitive_opt_in_at is not null,
    'credits', coalesce((select sum(amount) from public.credit_ledger where user_id = p.id), 0),
    'unlimited', public.has_unlimited_slashes(p.id),
    'daily_done', (u->>'daily_done')::boolean,
    -- one of the five is always kept for the daily question
    'answers_left_today', public.cfg('answers_per_day') - (u->>'others')::int
                          - case when (u->>'daily_done')::boolean then 1 else 0 end,
    'other_answers_left_today', public.cfg('answers_per_day') - 1 - (u->>'others')::int,
    'changes_left_today', public.cfg('changes_per_day') - (u->>'changes')::int,
    'predictions', public.hit_rate(p.id),
    'created_at', p.created_at)
  from public.profiles p, used where p.id = auth.uid()
$$;

notify pgrst, 'reload schema';
