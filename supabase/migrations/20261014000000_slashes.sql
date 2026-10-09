-- Credits are called slashes in the app now. Only the wording people see
-- changes; the tables and settings keep their names (credit_ledger,
-- send_cost, challenge_reward, signup_credits).
--
-- Safe to run twice.

create or replace function public.send_challenge(p_handle text, p_question bigint, p_minutes int default 1440)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); target uuid; bal int;
begin
  if p_minutes not in (1, 60, 1440) then raise exception 'Pick 1 minute, 1 hour or 1 day'; end if;
  select id into target from public.profiles where handle = lower(p_handle);
  if target is null then raise exception 'No one with that handle'; end if;
  if not public.are_friends(uid, target) then
    raise exception 'You can only send questions to friends (people who follow you back)';
  end if;
  if exists (select 1 from public.questions where id = p_question and (sensitivity = 'sensitive' or is_event)) then
    raise exception 'Sensitive questions can''t be sent to friends';
  end if;
  if not exists (select 1 from public.statements where user_id = uid and question_id = p_question and superseded_at is null) then
    raise exception 'Answer it yourself first';
  end if;
  if exists (select 1 from public.statements where user_id = target and question_id = p_question and superseded_at is null) then
    raise exception 'They have already answered that one';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < public.cfg('send_cost') then raise exception 'Sending costs % slashes', public.cfg('send_cost'); end if;

  insert into public.challenges (from_user, to_user, question_id, expires_at)
  values (uid, target, p_question, now() + make_interval(mins => p_minutes));
  insert into public.credit_ledger (user_id, amount, reason, question_id)
  values (uid, -public.cfg('send_cost'), 'send', p_question);
exception when unique_violation then
  raise exception 'You already sent them that question';
end $$;

notify pgrst, 'reload schema';
