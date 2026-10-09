-- The Predict tab is now Future, and it starts locked. Unlocking it costs
-- 100 slashes, once, and needs a date of birth showing 18 or over. The cost
-- keeps throwaway accounts out, since a new account starts with 10.
-- The unlock is a credit_ledger row with the reason 'future_unlock', so it
-- shows in slash history and the data download like any other spend.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('future_unlock_cost', 100)    -- slashes to unlock the Future tab, once
on conflict (key) do nothing;

create or replace function public.future_unlocked(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.credit_ledger where user_id = p_user and reason = 'future_unlock')
$$;

create or replace function public.unlock_future() returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); bal int; cost int := public.cfg('future_unlock_cost');
begin
  if not public.is_adult(uid) then
    raise exception 'Future is for people aged % and over', public.cfg('adult_age');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  if public.future_unlocked(uid) then return; end if;
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < cost then raise exception 'Unlocking Future costs % slashes and you have %', cost, bal; end if;
  insert into public.credit_ledger (user_id, amount, reason) values (uid, -cost, 'future_unlock');
end $$;

-- Guesses need Future unlocked. Everything else is as before.
create or replace function public.predict(p_kind text, p_question bigint, p_yes boolean, p_friend text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); target uuid; q public.questions;
begin
  if not public.future_unlocked(uid) then
    raise exception 'Unlock Future first';
  end if;

  select * into q from public.questions where id = p_question and status = 'approved'
     and (daily_date is null or daily_date <= public.today_uk())
     and (sensitivity <> 'sensitive' or public.is_adult(uid));
  if not found then raise exception 'Question not found'; end if;

  if p_kind = 'crowd' then
    if q.daily_date is distinct from public.today_uk() then
      raise exception 'Crowd guesses are for today''s question';
    end if;
  elsif p_kind = 'event' then
    if not q.is_event or q.closes_at <= now() or q.outcome is not null then
      raise exception 'This event is closed';
    end if;
  elsif p_kind = 'friend' then
    select id into target from public.profiles where handle = lower(p_friend);
    if target is null or not public.are_friends(uid, target) then
      raise exception 'You can only guess friends'' answers';
    end if;
    if q.is_event or q.sensitivity = 'sensitive' then raise exception 'Pick another question'; end if;
    if exists (select 1 from public.statements where user_id = target and question_id = p_question) then
      raise exception 'They have already answered that one';
    end if;
  else
    raise exception 'Unknown prediction type';
  end if;

  insert into public.predictions (user_id, kind, question_id, target_user, predicts_yes)
  values (uid, p_kind, p_question, target, p_yes);
exception when unique_violation then
  raise exception 'You already made that guess';
end $$;

revoke execute on function public.future_unlocked(uuid), public.unlock_future() from public, anon;
grant execute on function public.unlock_future() to authenticated;

notify pgrst, 'reload schema';
