-- Making questions, and what things cost in slashes.
--
--   * Sending a friend a question you've answered costs 2 slashes (was 3).
--   * Friend questions: anyone can write a private question for their friends
--     and send it to some of them. No approval needed, only friends can see
--     it, answers never go public, and answering one doesn't use up your
--     daily five. It costs 3 slashes including the first friend, then the
--     usual 2 for each extra friend.
--   * Public questions still wait for a moderator, and now cost 5 slashes.
--
-- Safe to run twice.

update public.app_config set value = 2 where key = 'send_cost' and value = 3;
insert into public.app_config (key, value) values
  ('friend_question_cost', 3),   -- write a question for friends and send it to one of them
  ('public_question_cost', 5)    -- suggest a question for everyone (a moderator checks it)
on conflict (key) do nothing;

alter table public.questions add column if not exists audience text not null default 'public';
do $$ begin
  alter table public.questions add constraint questions_audience check (audience in ('public', 'friends'));
exception when duplicate_object then null; end $$;

-- Who can see a question, from the app's side or the database's.
create or replace function public.can_see_question(p_user uuid, q public.questions) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when q.created_by = p_user then true
    when q.audience = 'friends' then
      q.status = 'approved' and (public.are_friends(p_user, q.created_by)
        or exists (select 1 from public.challenges where to_user = p_user and question_id = q.id))
    else q.status = 'approved' and (q.daily_date is null or q.daily_date <= public.today_uk())
      and (q.sensitivity <> 'sensitive' or public.is_adult(p_user))
  end
$$;
grant execute on function public.can_see_question(uuid, public.questions) to authenticated;

drop policy if exists "read questions" on public.questions;
create policy "read questions" on public.questions for select to authenticated
  using (public.can_see_question(auth.uid(), questions));

-- ---------------------------------------------------------------------------
-- Answering: friend questions stay with friends and sit outside the daily five
-- ---------------------------------------------------------------------------

create or replace function public.answer(p_question bigint, p_value boolean, p_visibility public.visibility default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.require_profile();
  q public.questions;
  cur public.statements;
  had boolean;
  vis public.visibility;
  is_daily boolean;
  challenged boolean;
  for_friends boolean;
  used json;
  ch record;
begin
  select * into q from public.questions
   where id = p_question and status = 'approved' and not is_event
     and (daily_date is null or daily_date <= public.today_uk());
  if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
  is_daily := q.daily_date is not distinct from public.today_uk();
  for_friends := q.audience = 'friends';

  if q.sensitivity = 'sensitive' then
    if not public.is_adult(uid) then raise exception 'Sensitive questions are for over-18s'; end if;
    if not exists (select 1 from public.profiles where id = uid and sensitive_opt_in_at is not null) then
      raise exception 'Turn on sensitive questions first';
    end if;
  end if;

  select * into cur from public.statements
   where user_id = uid and question_id = p_question and superseded_at is null
   for update;
  had := found;

  if had and cur.value = p_value then
    return public.question_split(p_question);
  end if;

  -- Sensitive answers always start private; otherwise your last choice carries over.
  if q.sensitivity = 'sensitive' then
    vis := coalesce(p_visibility, cur.visibility, 'private');
  else
    vis := coalesce(p_visibility, cur.visibility,
                    (select last_visibility from public.profiles where id = uid),
                    case when q.sensitivity = 'standard' and public.cfg('new_answers_public') = 1
                         then 'public'::public.visibility else 'friends'::public.visibility end);
    if p_visibility is not null then
      update public.profiles set last_visibility = p_visibility where id = uid;
    end if;
  end if;
  if vis = 'public' and (for_friends or not public.is_adult(uid)) then vis := 'friends'; end if;

  used := public.answers_used_today(uid);

  if had then
    if cur.verified then raise exception 'This answer was verified by %; change it there', cur.source; end if;
    if (used->>'changes')::int >= public.cfg('changes_per_day') then
      raise exception 'You have used today''s change of mind';
    end if;
    update public.statements set superseded_at = now() where id = cur.id;
    insert into public.statements (user_id, question_id, value, visibility, replaces, hidden_until)
    values (uid, p_question, p_value, vis, cur.id,
            now() + make_interval(days => public.cfg('change_hidden_days')));
    return public.question_split(p_question);
  end if;

  -- A question a friend sent you, still on the clock, doesn't use up the daily five.
  -- Neither does any question a friend wrote.
  challenged := exists (select 1 from public.challenges
                         where to_user = uid and question_id = p_question
                           and answered_at is null and expires_at > now());

  if not is_daily and not challenged and not for_friends
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 then
    raise exception 'That''s your answers for today. One is always kept for the daily question, so come back tomorrow';
  end if;

  insert into public.statements (user_id, question_id, value, visibility, via_challenge)
  values (uid, p_question, p_value, vis, (challenged or for_friends) and not is_daily);

  for ch in
    update public.challenges set answered_at = now()
     where to_user = uid and question_id = p_question and answered_at is null and expires_at > now()
    returning id
  loop
    insert into public.credit_ledger (user_id, amount, reason, question_id)
    values (uid, public.cfg('challenge_reward'), 'challenge', p_question);
  end loop;

  -- Friends who guessed this answer find out if they were right, unless it's private.
  update public.predictions
     set resolved_at = now(),
         correct = case when vis = 'private' then null else predicts_yes = p_value end
   where kind = 'friend' and target_user = uid and question_id = p_question and resolved_at is null;

  return public.question_split(p_question);
end $$;

create or replace function public.set_visibility(p_question bigint, p_visibility public.visibility)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  if p_visibility = 'public' and not public.is_adult(uid) then
    raise exception 'Under-18 answers can be shown to friends at most';
  end if;
  if p_visibility = 'public' and exists (select 1 from public.questions where id = p_question and audience = 'friends') then
    raise exception 'Answers to friend questions stay with friends';
  end if;
  update public.statements set visibility = p_visibility
   where user_id = uid and question_id = p_question and superseded_at is null;
  if not exists (select 1 from public.questions where id = p_question and sensitivity = 'sensitive') then
    update public.profiles set last_visibility = p_visibility where id = uid;
  end if;
end $$;

-- The daily question only ever comes from the public bank.
create or replace function public.ensure_daily() returns void
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  foreach d in array array[public.today_uk(), public.today_uk() + 1] loop
    if not exists (select 1 from public.questions where daily_date = d) then
      update public.questions set daily_date = d
       where id = (select id from public.questions
                    where status = 'approved' and sensitivity = 'standard' and not is_event
                      and audience = 'public' and daily_date is null
                    order by id limit 1);
    end if;
  end loop;
end $$;

-- Sending on: a friend question only ever reaches friends of the person who wrote it.
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
  if exists (select 1 from public.questions where id = p_question and audience = 'friends'
               and created_by is distinct from target and not public.are_friends(target, created_by)) then
    raise exception 'Only friends of the person who wrote it can get this question';
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

-- ---------------------------------------------------------------------------
-- Making questions
-- ---------------------------------------------------------------------------

-- Write a question for friends, answer it, and send it to the friends picked.
create or replace function public.make_friend_question(p_text text, p_value boolean, p_handles text[], p_minutes int default 1440)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.require_profile();
  targets uuid[] := '{}';
  h text;
  t uuid;
  cost int;
  bal int;
  new_id bigint;
begin
  if char_length(trim(coalesce(p_text, ''))) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  if p_value is null then raise exception 'Pick your own answer first'; end if;
  if p_minutes not in (1, 60, 1440) then raise exception 'Pick 1 minute, 1 hour or 1 day'; end if;
  foreach h in array coalesce(p_handles, '{}') loop
    select id into t from public.profiles where handle = lower(h);
    if t is null or not public.are_friends(uid, t) then
      raise exception 'You can only send questions to friends (people who follow you back)';
    end if;
    if not t = any(targets) then targets := targets || t; end if;
  end loop;
  if cardinality(targets) = 0 then raise exception 'Pick at least one friend to send it to'; end if;

  cost := public.cfg('friend_question_cost') + public.cfg('send_cost') * (cardinality(targets) - 1);
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < cost then raise exception 'That costs % slashes and you have %', cost, bal; end if;

  insert into public.questions (text, category, status, audience, created_by)
  values (trim(p_text), 'Friends', 'approved', 'friends', uid) returning id into new_id;
  insert into public.statements (user_id, question_id, value, visibility, via_challenge)
  values (uid, new_id, p_value, 'friends', true);
  insert into public.challenges (from_user, to_user, question_id, expires_at)
  select uid, x, new_id, now() + make_interval(mins => p_minutes) from unnest(targets) x;
  insert into public.credit_ledger (user_id, amount, reason, question_id)
  values (uid, -cost, 'friend_question', new_id);
  return new_id;
end $$;

-- Suggest a question for everyone. A moderator approves it (status) before it goes live.
create or replace function public.submit_question(p_text text, p_category text default 'General')
returns bigint language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); new_id bigint; bal int;
begin
  if char_length(trim(coalesce(p_text, ''))) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  if (select count(*) from public.questions
       where created_by = uid and audience = 'public' and created_at >= public.uk_day_start()) >= 3 then
    raise exception 'Three suggestions a day';
  end if;
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < public.cfg('public_question_cost') then
    raise exception 'Suggesting a question costs % slashes and you have %', public.cfg('public_question_cost'), bal;
  end if;
  insert into public.questions (text, category, status, created_by)
  values (trim(p_text), coalesce(nullif(trim(p_category), ''), 'General'), 'pending', uid) returning id into new_id;
  insert into public.credit_ledger (user_id, amount, reason, question_id)
  values (uid, -public.cfg('public_question_cost'), 'suggest', new_id);
  return new_id;
end $$;

grant execute on function public.make_friend_question(text, boolean, text[], int) to authenticated;

notify pgrst, 'reload schema';
