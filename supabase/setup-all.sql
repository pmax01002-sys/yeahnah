-- yeah/nah demo: whole database in one go, for a NEW Supabase project. Paste into SQL Editor and press Run.
-- (The migrations in supabase/migrations, in order, then supabase/seed.sql.)
-- Already set up? Run only the newer migration files instead.

-- yeah/nah demo backend: one Postgres database on Supabase.
--
-- Design rules (from the MVP backend plan):
--   * Every answer is a yes/no "statement": one person, one question, a value,
--     a source and a date. Typed answers and partner apps (Strava etc.) land
--     in the same table, so a new partner never needs a schema change.
--   * Statements are never overwritten. A change of mind adds a row and marks
--     the old one superseded.
--   * Clients read through row-level security but write only through the
--     functions below, which enforce the daily limits and privacy rules.
--   * Credits are free play credits. Real money never touches this database.
--
-- Game rules match the clickable prototype (v3). Every number lives in
-- app_config so it can be changed without touching code.

-- ---------------------------------------------------------------------------
-- Settings and helpers
-- ---------------------------------------------------------------------------

create table public.app_config (
  key text primary key,
  value int not null
);

insert into public.app_config (key, value) values
  ('answers_per_day', 5),        -- own answers per UK day, one kept for the daily question
  ('changes_per_day', 1),        -- changes of mind per UK day
  ('change_hidden_days', 7),     -- a changed answer is hidden from others this long
  ('signup_credits', 10),
  ('send_cost', 3),              -- credits to send a question to a friend
  ('challenge_reward', 2),       -- credits for answering a friend's question in time
  ('min_age', 13),
  ('adult_age', 18);

create function public.cfg(p_key text) returns int
language sql stable security definer set search_path = '' as $$
  select value from public.app_config where key = p_key
$$;

-- The app's day runs on UK time.
create function public.today_uk() returns date
language sql stable as $$
  select (now() at time zone 'Europe/London')::date
$$;

create function public.uk_day_start() returns timestamptz
language sql stable as $$
  select (public.today_uk()::timestamp at time zone 'Europe/London')
$$;

create type public.visibility as enum ('public', 'friends', 'private');
create type public.sensitivity as enum ('standard', 'personal', 'sensitive');

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  handle text not null unique check (handle ~ '^[a-z0-9_]{3,20}$'),  -- stored lower case
  display_name text not null check (char_length(display_name) between 1 and 40),
  birth_date date not null,
  sensitive_opt_in_at timestamptz,
  last_visibility public.visibility,   -- carries over to the next non-sensitive answer
  created_at timestamptz not null default now()
);

-- Others may see who you are, never your date of birth.
revoke all on public.profiles from anon, authenticated;
grant select (id, handle, display_name, created_at) on public.profiles to authenticated;

create function public.is_adult(p_user uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select age(p.birth_date) >= make_interval(years => public.cfg('adult_age'))
       from public.profiles p where p.id = p_user),
    false)
$$;

create table public.follows (
  follower uuid not null references public.profiles (id) on delete cascade,
  followed uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower, followed),
  check (follower <> followed)
);

-- Friends = people who follow each other.
create function public.are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.follows where follower = a and followed = b)
     and exists (select 1 from public.follows where follower = b and followed = a)
$$;

create table public.consents (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  purpose text not null,               -- 'terms', 'sensitive_questions', ...
  policy_version text not null default 'demo-1',
  granted_at timestamptz not null default now(),
  withdrawn_at timestamptz
);

-- ---------------------------------------------------------------------------
-- Questions
-- ---------------------------------------------------------------------------

create table public.questions (
  id bigint generated always as identity primary key,
  text text not null check (char_length(text) between 5 and 140),
  category text not null default 'General',
  sensitivity public.sensitivity not null default 'standard',
  -- "Pick" questions (Nike or Reebok?) are still stored as yes/no:
  -- choosing option_yes = YES.
  option_yes text,
  option_no text,
  emoji_yes text,
  emoji_no text,
  partner text,                        -- an app that can verify it, e.g. 'Strava'
  daily_date date unique,              -- set = this is that day's question
  -- World events ("Will it snow in London on Christmas Day?") are only
  -- predicted, never answered about yourself. An editor sets the outcome.
  is_event boolean not null default false,
  closes_at timestamptz,
  outcome boolean,
  status text not null default 'approved' check (status in ('pending', 'approved', 'rejected')),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((option_yes is null) = (option_no is null)),
  check (not is_event or closes_at is not null)
);

-- ---------------------------------------------------------------------------
-- Statements: every yes/no fact about a person
-- ---------------------------------------------------------------------------

create table public.statements (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  value boolean not null,
  source text not null default 'app',  -- 'app', 'strava', 'apple_health', ...
  verified boolean not null default false,
  visibility public.visibility not null,
  replaces bigint references public.statements (id),
  via_challenge boolean not null default false,  -- answered a friend's question; outside the daily 5
  hidden_until timestamptz,            -- a change of mind stays hidden from others until then
  created_at timestamptz not null default now(),
  superseded_at timestamptz
);

create unique index statements_current on public.statements (user_id, question_id)
  where superseded_at is null;
create index statements_question on public.statements (question_id) where superseded_at is null;
create index statements_user_day on public.statements (user_id, created_at);

-- ---------------------------------------------------------------------------
-- Credits, predictions and friend challenges
-- ---------------------------------------------------------------------------

create table public.credit_ledger (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount int not null,
  reason text not null,                -- 'signup', 'send', 'challenge'
  question_id bigint references public.questions (id) on delete set null,
  created_at timestamptz not null default now()
);
create index credit_ledger_user on public.credit_ledger (user_id);

-- Free guesses that build a hit rate:
--   crowd  - will today's daily question end the day on YEAH?
--   friend - what will this friend answer?
--   event  - will this world event happen?
create table public.predictions (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null check (kind in ('crowd', 'friend', 'event')),
  question_id bigint not null references public.questions (id) on delete cascade,
  target_user uuid references public.profiles (id) on delete cascade,
  predicts_yes boolean not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  correct boolean,                     -- null once resolved = void (tie, private answer)
  check ((kind = 'friend') = (target_user is not null))
);
create unique index predictions_one_each on public.predictions
  (user_id, kind, question_id, coalesce(target_user, '00000000-0000-0000-0000-000000000000'));

create table public.challenges (
  id bigint generated always as identity primary key,
  from_user uuid not null references public.profiles (id) on delete cascade,
  to_user uuid not null references public.profiles (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  answered_at timestamptz,
  unique (from_user, to_user, question_id)
);

create table public.reports (
  id bigint generated always as identity primary key,
  reporter uuid not null references public.profiles (id) on delete cascade,
  target_user uuid references public.profiles (id) on delete cascade,
  question_id bigint references public.questions (id) on delete cascade,
  reason text not null check (char_length(reason) between 3 and 500),
  status text not null default 'open' check (status in ('open', 'actioned', 'dismissed')),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Row-level security: what each signed-in person can read
-- ---------------------------------------------------------------------------

alter table public.app_config enable row level security;
alter table public.profiles enable row level security;
alter table public.follows enable row level security;
alter table public.consents enable row level security;
alter table public.questions enable row level security;
alter table public.statements enable row level security;
alter table public.credit_ledger enable row level security;
alter table public.predictions enable row level security;
alter table public.challenges enable row level security;
alter table public.reports enable row level security;

-- Nothing here is readable without signing in.
revoke all on all tables in schema public from anon;

create policy "read config" on public.app_config for select to authenticated using (true);

create policy "read profiles" on public.profiles for select to authenticated using (true);

create policy "read follows" on public.follows for select to authenticated
  using (follower = auth.uid() or followed = auth.uid());
create policy "follow" on public.follows for insert to authenticated
  with check (follower = auth.uid());
create policy "unfollow" on public.follows for delete to authenticated
  using (follower = auth.uid());

create policy "own consents" on public.consents for select to authenticated
  using (user_id = auth.uid());

-- Approved questions up to today. Tomorrow's daily question stays hidden,
-- and sensitive questions are invisible to under-18s.
create policy "read questions" on public.questions for select to authenticated
  using (
    (status = 'approved' and (daily_date is null or daily_date <= public.today_uk())
      and (sensitivity <> 'sensitive' or public.is_adult(auth.uid())))
    or created_by = auth.uid()
  );

-- Your own answers, plus other people's current answers they chose to show
-- you. A fresh change of mind stays hidden for a week.
create policy "read statements" on public.statements for select to authenticated
  using (
    user_id = auth.uid()
    or (superseded_at is null
        and (hidden_until is null or hidden_until < now())
        and (visibility = 'public'
             or (visibility = 'friends' and public.are_friends(auth.uid(), user_id))))
  );

create policy "own credits" on public.credit_ledger for select to authenticated
  using (user_id = auth.uid());
create policy "own predictions" on public.predictions for select to authenticated
  using (user_id = auth.uid());
create policy "own challenges" on public.challenges for select to authenticated
  using (from_user = auth.uid() or to_user = auth.uid());
create policy "own reports" on public.reports for select to authenticated
  using (reporter = auth.uid());

-- Writes go through the functions below, except following.
revoke insert, update, delete on all tables in schema public from authenticated;
grant insert, delete on public.follows to authenticated;

-- ---------------------------------------------------------------------------
-- Functions the app calls (all check who is calling)
-- ---------------------------------------------------------------------------

create function public.require_profile() returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if not exists (select 1 from public.profiles where id = uid) then
    raise exception 'Create your profile first';
  end if;
  return uid;
end $$;

create function public.create_profile(p_handle text, p_display_name text, p_birth_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_birth_date is null or age(p_birth_date) < make_interval(years => public.cfg('min_age')) then
    raise exception 'yeah/nah is for people aged 13 and over';
  end if;
  insert into public.profiles (id, handle, display_name, birth_date)
  values (uid, lower(trim(p_handle)), trim(p_display_name), p_birth_date);
  insert into public.consents (user_id, purpose) values (uid, 'terms');
  insert into public.credit_ledger (user_id, amount, reason)
  values (uid, public.cfg('signup_credits'), 'signup');
exception
  when unique_violation then raise exception 'That handle is taken';
  when check_violation then raise exception 'Handles are 3 to 20 letters, numbers or underscores';
end $$;

-- Own answers today, split into the daily question and the rest.
create function public.answers_used_today(p_user uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'daily_done', exists (
      select 1 from public.statements s join public.questions q on q.id = s.question_id
       where s.user_id = p_user and q.daily_date = public.today_uk()),
    'others', (select count(*) from public.statements s join public.questions q on q.id = s.question_id
                where s.user_id = p_user and s.source = 'app' and s.replaces is null and not s.via_challenge
                  and s.created_at >= public.uk_day_start()
                  and q.daily_date is distinct from public.today_uk()),
    'changes', (select count(*) from public.statements
                 where user_id = p_user and source = 'app' and replaces is not null
                   and created_at >= public.uk_day_start()))
$$;

create function public.hit_rate(p_user uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'made', count(*),
    'resolved', count(*) filter (where correct is not null),
    'correct', count(*) filter (where correct),
    'rate', round(100.0 * count(*) filter (where correct) / nullif(count(*) filter (where correct is not null), 0)))
  from public.predictions where user_id = p_user
$$;

create function public.my_profile() returns json
language sql stable security definer set search_path = '' as $$
  with used as (select public.answers_used_today(auth.uid()) as u)
  select json_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name,
    'is_adult', public.is_adult(p.id),
    'sensitive_opt_in', p.sensitive_opt_in_at is not null,
    'credits', coalesce((select sum(amount) from public.credit_ledger where user_id = p.id), 0),
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

-- Public card for someone else's profile: hit rate and answer count.
create function public.profile_card(p_handle text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'handle', p.handle, 'display_name', p.display_name,
    'is_friend', public.are_friends(auth.uid(), p.id),
    'i_follow', exists (select 1 from public.follows where follower = auth.uid() and followed = p.id),
    'follows_me', exists (select 1 from public.follows where follower = p.id and followed = auth.uid()),
    'predictions', public.hit_rate(p.id),
    'joined', p.created_at)
  from public.profiles p where p.handle = lower(p_handle)
$$;

create function public.set_sensitive_opt_in(p_on boolean) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  if p_on then
    if not public.is_adult(uid) then raise exception 'Sensitive questions are for over-18s'; end if;
    update public.profiles set sensitive_opt_in_at = now() where id = uid and sensitive_opt_in_at is null;
    insert into public.consents (user_id, purpose) values (uid, 'sensitive_questions');
  else
    update public.profiles set sensitive_opt_in_at = null where id = uid;
    update public.consents set withdrawn_at = now()
     where user_id = uid and purpose = 'sensitive_questions' and withdrawn_at is null;
    -- Withdrawing consent hides those answers from everyone else.
    update public.statements s set visibility = 'private'
      from public.questions q
     where s.question_id = q.id and s.user_id = uid and q.sensitivity = 'sensitive';
  end if;
end $$;

-- Crowd split. Only returned once you have answered.
create function public.question_split(p_question bigint) returns json
language sql stable security definer set search_path = '' as $$
  select case when exists (
      select 1 from public.statements
       where user_id = auth.uid() and question_id = p_question and superseded_at is null)
    then (select json_build_object(
            'yes', count(*) filter (where value),
            'no', count(*) filter (where not value),
            'total', count(*))
          from public.statements
         where question_id = p_question and superseded_at is null)
    else null end
$$;

create function public.answer(p_question bigint, p_value boolean, p_visibility public.visibility default null)
returns json language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.require_profile();
  q public.questions;
  cur public.statements;
  had boolean;
  vis public.visibility;
  is_daily boolean;
  challenged boolean;
  used json;
  ch record;
begin
  select * into q from public.questions
   where id = p_question and status = 'approved' and not is_event
     and (daily_date is null or daily_date <= public.today_uk());
  if not found then raise exception 'Question not found'; end if;
  is_daily := q.daily_date is not distinct from public.today_uk();

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
                    case q.sensitivity when 'personal' then 'friends'::public.visibility
                                       else 'public'::public.visibility end);
    if p_visibility is not null then
      update public.profiles set last_visibility = p_visibility where id = uid;
    end if;
  end if;
  if vis = 'public' and not public.is_adult(uid) then vis := 'friends'; end if;  -- under-18s never public

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
  challenged := exists (select 1 from public.challenges
                         where to_user = uid and question_id = p_question
                           and answered_at is null and expires_at > now());

  if not is_daily and not challenged
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 then
    raise exception 'That''s your answers for today. One is always kept for the daily question, so come back tomorrow';
  end if;

  insert into public.statements (user_id, question_id, value, visibility, via_challenge)
  values (uid, p_question, p_value, vis, challenged and not is_daily);

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

create function public.set_visibility(p_question bigint, p_visibility public.visibility)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  if p_visibility = 'public' and not public.is_adult(uid) then
    raise exception 'Under-18 answers can be shown to friends at most';
  end if;
  update public.statements set visibility = p_visibility
   where user_id = uid and question_id = p_question and superseded_at is null;
  if not exists (select 1 from public.questions where id = p_question and sensitivity = 'sensitive') then
    update public.profiles set last_visibility = p_visibility where id = uid;
  end if;
end $$;

-- How your friends answered. Only after you have answered yourself.
create function public.friends_answers(p_question bigint)
returns table (handle text, display_name text, value boolean)
language sql stable security definer set search_path = '' as $$
  select p.handle, p.display_name, s.value
    from public.statements s
    join public.profiles p on p.id = s.user_id
   where s.question_id = p_question and s.superseded_at is null
     and (s.hidden_until is null or s.hidden_until < now())
     and s.visibility in ('public', 'friends')
     and public.are_friends(auth.uid(), s.user_id)
     and exists (select 1 from public.statements m
                  where m.user_id = auth.uid() and m.question_id = p_question and m.superseded_at is null)
$$;

-- "You agree on 72%": compares only answers the other person lets you see.
create function public.agreement_with(p_handle text) returns json
language sql stable security invoker set search_path = '' as $$
  with pairs as (
    select m.value = o.value as same
      from public.statements m
      join public.statements o on o.question_id = m.question_id
     where m.user_id = auth.uid() and m.superseded_at is null
       and o.user_id = (select id from public.profiles where handle = lower(p_handle))
       and o.superseded_at is null)
  select json_build_object('both', count(*), 'agree', count(*) filter (where same)) from pairs
$$;

-- Free guesses. p_friend is a handle, only for kind 'friend'.
create function public.predict(p_kind text, p_question bigint, p_yes boolean, p_friend text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); target uuid; q public.questions;
begin
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

-- Resolve crowd guesses for finished days. Exact ties are void.
create function public.resolve_due() returns int
language plpgsql security definer set search_path = '' as $$
declare q record; yes_n int; no_n int; n int := 0;
begin
  for q in
    select distinct qu.id from public.questions qu
      join public.predictions p on p.question_id = qu.id and p.kind = 'crowd' and p.resolved_at is null
     where qu.daily_date < public.today_uk()
  loop
    select count(*) filter (where value), count(*) filter (where not value) into yes_n, no_n
      from public.statements where question_id = q.id and superseded_at is null;
    update public.predictions
       set resolved_at = now(),
           correct = case when yes_n = no_n then null else predicts_yes = (yes_n > no_n) end
     where question_id = q.id and kind = 'crowd' and resolved_at is null;
    n := n + 1;
  end loop;
  return n;
end $$;

-- An editor settles a world event (from the dashboard or an admin tool).
create function public.resolve_event(p_question bigint, p_outcome boolean) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.questions set outcome = p_outcome where id = p_question and is_event;
  if not found then raise exception 'Not an event'; end if;
  update public.predictions set resolved_at = now(), correct = predicts_yes = p_outcome
   where question_id = p_question and kind = 'event' and resolved_at is null;
end $$;

-- Send a question to a friend with a timer: 1 minute, 1 hour or 1 day.
create function public.send_challenge(p_handle text, p_question bigint, p_minutes int default 1440)
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
  if bal < public.cfg('send_cost') then raise exception 'Sending costs % credits', public.cfg('send_cost'); end if;

  insert into public.challenges (from_user, to_user, question_id, expires_at)
  values (uid, target, p_question, now() + make_interval(mins => p_minutes));
  insert into public.credit_ledger (user_id, amount, reason, question_id)
  values (uid, -public.cfg('send_cost'), 'send', p_question);
exception when unique_violation then
  raise exception 'You already sent them that question';
end $$;

create function public.submit_question(p_text text, p_category text default 'General')
returns bigint language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); new_id bigint;
begin
  if (select count(*) from public.questions where created_by = uid and created_at >= public.uk_day_start()) >= 3 then
    raise exception 'Three suggestions a day';
  end if;
  insert into public.questions (text, category, status, created_by)
  values (trim(p_text), coalesce(p_category, 'General'), 'pending', uid) returning id into new_id;
  return new_id;
end $$;

create function public.report(p_reason text, p_target_handle text default null, p_question bigint default null)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  insert into public.reports (reporter, target_user, question_id, reason)
  values (uid, (select id from public.profiles where handle = lower(p_target_handle)), p_question, p_reason);
end $$;

-- Partner apps (Strava etc.) write verified statements. Server side only:
-- called by an Edge Function holding the service key, never by the app.
create function public.partner_write(p_user uuid, p_question bigint, p_value boolean, p_source text)
returns void language plpgsql security definer set search_path = '' as $$
declare cur public.statements; had boolean;
begin
  select * into cur from public.statements
   where user_id = p_user and question_id = p_question and superseded_at is null for update;
  had := found;
  if had and cur.value = p_value and cur.verified then return; end if;
  if had then update public.statements set superseded_at = now() where id = cur.id; end if;
  insert into public.statements (user_id, question_id, value, source, verified, visibility, replaces)
  values (p_user, p_question, p_value, p_source, true, coalesce(cur.visibility, 'friends'), cur.id);
end $$;

-- Keep the daily slot filled: if today or tomorrow has no question, take the
-- next unused standard question from the bank.
create function public.ensure_daily() returns void
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  foreach d in array array[public.today_uk(), public.today_uk() + 1] loop
    if not exists (select 1 from public.questions where daily_date = d) then
      update public.questions set daily_date = d
       where id = (select id from public.questions
                    where status = 'approved' and sensitivity = 'standard' and not is_event
                      and daily_date is null
                    order by id limit 1);
    end if;
  end loop;
end $$;

-- UK GDPR: download my data, delete my account.
create function public.export_my_data() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'profile', (select row_to_json(p) from public.profiles p where id = auth.uid()),
    'statements', (select coalesce(json_agg(s order by s.created_at), '[]') from public.statements s where user_id = auth.uid()),
    'predictions', (select coalesce(json_agg(p), '[]') from public.predictions p where user_id = auth.uid()),
    'credits', (select coalesce(json_agg(c order by c.created_at), '[]') from public.credit_ledger c where user_id = auth.uid()),
    'consents', (select coalesce(json_agg(c), '[]') from public.consents c where user_id = auth.uid()),
    'follows', (select coalesce(json_agg(f), '[]') from public.follows f where follower = auth.uid() or followed = auth.uid()))
$$;

create function public.delete_my_account() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  delete from auth.users where id = auth.uid();
end $$;

-- ---------------------------------------------------------------------------
-- Function permissions: signed-in users only; server-only ones locked away
-- ---------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function
  public.today_uk(), public.uk_day_start(), public.cfg(text), public.is_adult(uuid), public.are_friends(uuid, uuid),
  public.create_profile(text, text, date), public.my_profile(), public.profile_card(text),
  public.set_sensitive_opt_in(boolean), public.question_split(bigint),
  public.answer(bigint, boolean, public.visibility), public.set_visibility(bigint, public.visibility),
  public.friends_answers(bigint), public.agreement_with(text),
  public.predict(text, bigint, boolean, text), public.send_challenge(text, bigint, int),
  public.submit_question(text, text), public.report(text, text, bigint),
  public.export_my_data(), public.delete_my_account()
to authenticated;
grant execute on function
  public.resolve_due(), public.resolve_event(bigint, boolean), public.ensure_daily(),
  public.partner_write(uuid, bigint, boolean, text)
to service_role;
alter default privileges in schema public revoke execute on functions from public, anon;

-- ---------------------------------------------------------------------------
-- Scheduled jobs (pg_cron is available on every Supabase project; skipped
-- where it isn't, e.g. a plain local Postgres)
-- ---------------------------------------------------------------------------

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('ensure-daily', '0 * * * *', 'select public.ensure_daily()');
  perform cron.schedule('resolve-predictions', '5 * * * *', 'select public.resolve_due()');
exception when others then
  raise notice 'pg_cron not available: run ensure_daily() and resolve_due() yourself';
end $$;

-- Friend groups and feedback, for sharing the demo with a few friends.
--
--   * A group has an invite link. Opening it and signing up joins the group.
--   * Joining makes you friends (mutual follows) with everyone already in it,
--     so sending questions and guessing each other's answers just work.
--   * The group board shows, per question, how each member answered. As with
--     the crowd split, you only see a question's answers once you have
--     answered it yourself. Private answers and fresh changes of mind stay
--     hidden, as everywhere else.
--   * Groups are 18+ in this demo, so no under-18 is put in touch with adults.
--   * Feedback goes into a table only the project owner reads (Table Editor).

create table public.groups (
  id bigint generated always as identity primary key,
  name text not null check (char_length(name) between 1 and 40),
  invite_code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  created_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now()
);

create table public.group_members (
  group_id bigint not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index group_members_user on public.group_members (user_id);

create table public.feedback (
  id bigint generated always as identity primary key,
  user_id uuid references public.profiles (id) on delete set null,
  body text not null check (char_length(body) between 2 and 2000),
  context text,                        -- which screen it was sent from
  created_at timestamptz not null default now()
);

create function public.is_group_member(p_group bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.group_members where group_id = p_group and user_id = auth.uid())
$$;

alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.feedback enable row level security;
revoke all on public.groups, public.group_members, public.feedback from anon;
revoke insert, update, delete on public.groups, public.group_members, public.feedback from authenticated;

create policy "my groups" on public.groups for select to authenticated
  using (public.is_group_member(id));
create policy "members of my groups" on public.group_members for select to authenticated
  using (public.is_group_member(group_id));
create policy "own feedback" on public.feedback for select to authenticated
  using (user_id = auth.uid());

-- Shown on the sign-up screen of an invite link, so it works signed out.
create function public.group_preview(p_code text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'name', g.name,
    'members', (select count(*) from public.group_members m where m.group_id = g.id),
    'invited_by', (select display_name from public.profiles where id = g.created_by))
  from public.groups g where g.invite_code = trim(p_code)
$$;

create function public.join_group_internal(p_group bigint, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.group_members (group_id, user_id) values (p_group, p_user)
  on conflict do nothing;
  -- Everyone in the group becomes friends with the newcomer, both ways.
  insert into public.follows (follower, followed)
  select p_user, m.user_id from public.group_members m where m.group_id = p_group and m.user_id <> p_user
  union all
  select m.user_id, p_user from public.group_members m where m.group_id = p_group and m.user_id <> p_user
  on conflict do nothing;
end $$;

create function public.create_group(p_name text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); g public.groups;
begin
  if not public.is_adult(uid) then raise exception 'Groups are for over-18s in this demo'; end if;
  if (select count(*) from public.groups where created_by = uid) >= 5 then
    raise exception 'You can make up to 5 groups';
  end if;
  insert into public.groups (name, created_by) values (trim(p_name), uid) returning * into g;
  perform public.join_group_internal(g.id, uid);
  return json_build_object('id', g.id, 'name', g.name, 'invite_code', g.invite_code);
end $$;

create function public.join_group(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); g public.groups;
begin
  select * into g from public.groups where invite_code = trim(p_code);
  if not found then raise exception 'That invite link doesn''t work any more'; end if;
  if not public.is_adult(uid) then raise exception 'Groups are for over-18s in this demo'; end if;
  if (select count(*) from public.group_members where group_id = g.id) >= 50 then
    raise exception 'This group is full';
  end if;
  perform public.join_group_internal(g.id, uid);
  return json_build_object('id', g.id, 'name', g.name);
end $$;

create function public.leave_group(p_group bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  delete from public.group_members where group_id = p_group and user_id = uid;
end $$;

-- A fresh invite code; the old link stops working. Creator only.
create function public.reset_invite(p_group bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare code text;
begin
  update public.groups set invite_code = substr(md5(random()::text || clock_timestamp()::text), 1, 10)
   where id = p_group and created_by = auth.uid() returning invite_code into code;
  if code is null then raise exception 'Only the person who made the group can do that'; end if;
  return code;
end $$;

-- Per question: how many members answered, and (once you have answered)
-- who said what. Newest activity first.
create function public.group_board(p_group bigint) returns json
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); result json;
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group'; end if;
  select coalesce(json_agg(b order by b.last_at desc), '[]') into result from (
    select s.question_id,
           count(*) as answered,
           max(s.created_at) as last_at,
           case when bool_or(s.user_id = uid) then
             json_agg(json_build_object('handle', p.handle, 'name', p.display_name, 'value', s.value, 'me', s.user_id = uid)
                      order by (s.user_id = uid) desc, p.display_name)
           end as answers
      from public.statements s
      join public.group_members gm on gm.user_id = s.user_id and gm.group_id = p_group
      join public.profiles p on p.id = s.user_id
     where s.superseded_at is null
       and (s.user_id = uid
            or (s.visibility in ('public', 'friends') and (s.hidden_until is null or s.hidden_until < now())))
     group by s.question_id) b;
  return result;
end $$;

create function public.submit_feedback(p_body text, p_context text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  if (select count(*) from public.feedback where user_id = uid and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Thanks! That''s plenty for one hour';
  end if;
  insert into public.feedback (user_id, body, context) values (uid, trim(p_body), left(p_context, 100));
end $$;

revoke execute on function public.is_group_member(bigint), public.group_preview(text),
  public.join_group_internal(bigint, uuid), public.create_group(text), public.join_group(text),
  public.leave_group(bigint), public.reset_invite(bigint), public.group_board(bigint),
  public.submit_feedback(text, text)
from public, anon, authenticated;
grant execute on function public.group_preview(text) to anon, authenticated;
grant execute on function public.is_group_member(bigint), public.create_group(text), public.join_group(text),
  public.leave_group(bigint), public.reset_invite(bigint), public.group_board(bigint),
  public.submit_feedback(text, text)
to authenticated;

-- Tell the API about the new tables and functions straight away.
notify pgrst, 'reload schema';

-- Adults only for now, and 79 themed questions in 11 themes.
--
-- Sign-up is 18+ while the demo is shared with friends. The under-18 rules
-- (friends-only answers, no sensitive questions, no groups) stay in place,
-- so lowering min_age in app_config turns teen accounts back on later.
--
-- Safe to run twice: questions already in the bank are skipped.

update public.app_config set value = 18 where key = 'min_age';

create or replace function public.create_profile(p_handle text, p_display_name text, p_birth_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_birth_date is null or age(p_birth_date) < make_interval(years => public.cfg('min_age')) then
    raise exception 'yeah/nah is for people aged % and over', public.cfg('min_age');
  end if;
  insert into public.profiles (id, handle, display_name, birth_date)
  values (uid, lower(trim(p_handle)), trim(p_display_name), p_birth_date);
  insert into public.consents (user_id, purpose) values (uid, 'terms');
  insert into public.credit_ledger (user_id, amount, reason)
  values (uid, public.cfg('signup_credits'), 'signup');
exception
  when unique_violation then raise exception 'That handle is taken';
  when check_violation then raise exception 'Handles are 3 to 20 letters, numbers or underscores';
end $$;

-- Themed packs. Picks ("Messi or Ronaldo?") are stored as yes/no like the
-- rest: the first option is YES.
insert into public.questions (text, category, sensitivity, option_yes, option_no, emoji_yes, emoji_no)
select v.text, v.category, v.sensitivity::public.sensitivity, v.option_yes, v.option_no, v.emoji_yes, v.emoji_no
from (values
  ('Is football overrated?', 'Sport', 'standard', null, null, null, null),
  ('Should VAR be scrapped?', 'Sport', 'standard', null, null, null, null),
  ('Is darts a real sport?', 'Sport', 'standard', null, null, null, null),
  ('Is esports a real sport?', 'Sport', 'standard', null, null, null, null),
  ('Should athletes caught doping be banned for life?', 'Sport', 'standard', null, null, null, null),
  ('Should the UK host the Olympics again?', 'Sport', 'standard', null, null, null, null),
  ('Is golf boring to watch?', 'Sport', 'standard', null, null, null, null),
  ('Messi or Ronaldo?', 'Sport', 'standard', 'Messi', 'Ronaldo', '🇦🇷', '🇵🇹'),
  ('Rugby or football?', 'Sport', 'standard', 'Rugby', 'Football', '🏉', '⚽'),
  ('Is vinyl better than streaming?', 'Music', 'standard', null, null, null, null),
  ('Should Eurovision be taken seriously?', 'Music', 'standard', null, null, null, null),
  ('Is karaoke fun?', 'Music', 'standard', null, null, null, null),
  ('Do you skip songs before they finish?', 'Music', 'standard', null, null, null, null),
  ('Have you ever been to a music festival?', 'Music', 'standard', null, null, null, null),
  ('Oasis or Blur?', 'Music', 'standard', 'Oasis', 'Blur', '🎸', '🎹'),
  ('Beatles or Stones?', 'Music', 'standard', 'Beatles', 'Stones', '🪲', '👅'),
  ('Is the book always better than the film?', 'Film & TV', 'standard', null, null, null, null),
  ('Is Die Hard a Christmas film?', 'Film & TV', 'standard', null, null, null, null),
  ('Have you ever cried at a film?', 'Film & TV', 'standard', null, null, null, null),
  ('Should films be shorter than two hours?', 'Film & TV', 'standard', null, null, null, null),
  ('Do you watch TV with subtitles on?', 'Film & TV', 'standard', null, null, null, null),
  ('Do you secretly enjoy reality TV?', 'Film & TV', 'standard', null, null, null, null),
  ('Marvel or DC?', 'Film & TV', 'standard', 'Marvel', 'DC', '🦸', '🦇'),
  ('Is a staycation better than going abroad?', 'Travel', 'standard', null, null, null, null),
  ('Would you go on holiday alone?', 'Travel', 'standard', null, null, null, null),
  ('Is camping a real holiday?', 'Travel', 'standard', null, null, null, null),
  ('Should you always learn a few words of the local language?', 'Travel', 'standard', null, null, null, null),
  ('Is it OK to recline on a train?', 'Travel', 'standard', null, null, null, null),
  ('Window or aisle?', 'Travel', 'standard', 'Window', 'Aisle', '🪟', '🚶'),
  ('City break or beach holiday?', 'Travel', 'standard', 'City break', 'Beach', '🏙️', '🏝️'),
  ('Should the four-day week be standard?', 'Work', 'standard', null, null, null, null),
  ('Should everyone know what their colleagues earn?', 'Work', 'standard', null, null, null, null),
  ('Would you take a pay cut to work from home?', 'Work', 'standard', null, null, null, null),
  ('Is it rude to wear headphones in the office?', 'Work', 'standard', null, null, null, null),
  ('Is it OK to look for jobs while at work?', 'Work', 'standard', null, null, null, null),
  ('Would you work unpaid for a year to land your dream job?', 'Work', 'standard', null, null, null, null),
  ('Do you like your job?', 'Work', 'personal', null, null, null, null),
  ('Should couples share their phone passwords?', 'Dating', 'standard', null, null, null, null),
  ('Is it OK to date a friend''s ex?', 'Dating', 'standard', null, null, null, null),
  ('Do you believe in soulmates?', 'Dating', 'standard', null, null, null, null),
  ('Is it OK to break up by text?', 'Dating', 'standard', null, null, null, null),
  ('Would you date someone with opposite politics?', 'Dating', 'standard', null, null, null, null),
  ('Should you meet a partner''s parents within three months?', 'Dating', 'standard', null, null, null, null),
  ('Have you ever used a dating app?', 'Dating', 'personal', null, null, null, null),
  ('Is a Jaffa Cake a biscuit?', 'Food', 'standard', null, null, null, null),
  ('Is cereal a soup?', 'Food', 'standard', null, null, null, null),
  ('Is brunch overrated?', 'Food', 'standard', null, null, null, null),
  ('Should ketchup be kept in the fridge?', 'Food', 'standard', null, null, null, null),
  ('Is a full English the best breakfast?', 'Food', 'standard', null, null, null, null),
  ('Milk in first?', 'Food', 'standard', null, null, null, null),
  ('Cheese or chocolate?', 'Food', 'standard', 'Cheese', 'Chocolate', '🧀', '🍫'),
  ('Is the Loch Ness Monster real?', 'Mysteries', 'standard', null, null, null, null),
  ('Have aliens visited Earth?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Area 51 hiding something?', 'Mysteries', 'standard', null, null, null, null),
  ('Are ghosts real?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Elvis still alive?', 'Mysteries', 'standard', null, null, null, null),
  ('Did Atlantis exist?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Bigfoot real?', 'Mysteries', 'standard', null, null, null, null),
  ('Would you get a brain chip if it was proven safe?', 'Future', 'standard', null, null, null, null),
  ('Should AI-made art be allowed to win prizes?', 'Future', 'standard', null, null, null, null),
  ('Would you want to live to 150?', 'Future', 'standard', null, null, null, null),
  ('Is social media doing more harm than good?', 'Future', 'standard', null, null, null, null),
  ('Would you swap your smartphone for a basic phone for a month?', 'Future', 'standard', null, null, null, null),
  ('Should cash be phased out?', 'Future', 'standard', null, null, null, null),
  ('Would you trust a robot to care for your parents?', 'Future', 'standard', null, null, null, null),
  ('Was music better in the 90s?', 'Nostalgia', 'standard', null, null, null, null),
  ('Do you miss life before smartphones?', 'Nostalgia', 'standard', null, null, null, null),
  ('Were the original Pokémon the best?', 'Nostalgia', 'standard', null, null, null, null),
  ('Should Blockbuster come back?', 'Nostalgia', 'standard', null, null, null, null),
  ('Was childhood better before the internet?', 'Nostalgia', 'standard', null, null, null, null),
  ('Did you have a Tamagotchi?', 'Nostalgia', 'standard', null, null, null, null),
  ('Nokia 3310 or Motorola Razr?', 'Nostalgia', 'standard', 'Nokia 3310', 'Razr', '🧱', '📞'),
  ('Spotify or Apple Music?', 'Brands', 'standard', 'Spotify', 'Apple Music', '🟢', '🍎'),
  ('Netflix or Disney+?', 'Brands', 'standard', 'Netflix', 'Disney+', '🎬', '🏰'),
  ('PlayStation or Xbox?', 'Brands', 'standard', 'PlayStation', 'Xbox', '🎮', '🟩'),
  ('Costa or Starbucks?', 'Brands', 'standard', 'Costa', 'Starbucks', '☕', '🧜'),
  ('Tesco or Sainsbury''s?', 'Brands', 'standard', 'Tesco', 'Sainsbury''s', '🛒', '🧡'),
  ('Uber or a black cab?', 'Brands', 'standard', 'Uber', 'Black cab', '🚗', '🚕'),
  ('Amazon or the high street?', 'Brands', 'standard', 'Amazon', 'High street', '📦', '🏪')
) as v(text, category, sensitivity, option_yes, option_no, emoji_yes, emoji_no)
where not exists (select 1 from public.questions q where q.text = v.text);

notify pgrst, 'reload schema';

-- Privacy fixes from a review of the demo.
--
--   * Profiles: you can only look up people you're connected to (friends,
--     follows either way, your groups, people you sent or got a question
--     from). Before, any signed-in person could list every handle and name.
--     Finding someone by their exact handle still works.
--   * Groups: leaving a group now ends the friendships that joining it made
--     (friends you added yourself, or share another group with, stay). The
--     person who made a group can remove someone, who then can't rejoin
--     with the same link.
--   * A setting for who sees new answers by default: new_answers_public in
--     app_config. 1 = standard answers start public, as in the prototype.
--     0 = they start friends-only. Personal answers start friends-only and
--     sensitive ones private, whatever it says. People can change any answer.
--
-- Safe to run twice.

insert into public.app_config (key, value) values ('new_answers_public', 1)
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Profiles: connected people only
-- ---------------------------------------------------------------------------

create or replace function public.knows(p_other uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select p_other = auth.uid()
      or exists (select 1 from public.follows
                  where (follower = auth.uid() and followed = p_other)
                     or (follower = p_other and followed = auth.uid()))
      or exists (select 1 from public.group_members a
                   join public.group_members b on b.group_id = a.group_id
                  where a.user_id = auth.uid() and b.user_id = p_other)
      or exists (select 1 from public.challenges
                  where (from_user = auth.uid() and to_user = p_other)
                     or (from_user = p_other and to_user = auth.uid()))
      or exists (select 1 from public.predictions
                  where user_id = auth.uid() and target_user = p_other)
$$;

drop policy if exists "read profiles" on public.profiles;
drop policy if exists "read connected profiles" on public.profiles;
create policy "read connected profiles" on public.profiles for select to authenticated
  using (public.knows(id));

-- The card you get by typing an exact handle now carries the id, so the
-- app can follow that person without reading the profiles table.
create or replace function public.profile_card(p_handle text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'id', p.id,
    'handle', p.handle, 'display_name', p.display_name,
    'is_friend', public.are_friends(auth.uid(), p.id),
    'i_follow', exists (select 1 from public.follows where follower = auth.uid() and followed = p.id),
    'follows_me', exists (select 1 from public.follows where follower = p.id and followed = auth.uid()),
    'predictions', public.hit_rate(p.id),
    'joined', p.created_at)
  from public.profiles p where p.handle = lower(p_handle)
$$;

-- ---------------------------------------------------------------------------
-- Groups: leaving undoes the friendships joining made; creators can remove
-- ---------------------------------------------------------------------------

alter table public.follows add column if not exists via_group boolean not null default false;

-- Follows made before this update between people who share a group came
-- from joining it (the demo had no other way to befriend a group).
update public.follows f set via_group = true
 where not f.via_group
   and exists (select 1 from public.group_members a
                 join public.group_members b on b.group_id = a.group_id
                where a.user_id = f.follower and b.user_id = f.followed);

create table if not exists public.group_removed (
  group_id bigint not null references public.groups (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  removed_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table public.group_removed enable row level security;
revoke all on public.group_removed from anon, authenticated;

create or replace function public.join_group_internal(p_group bigint, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.group_members (group_id, user_id) values (p_group, p_user)
  on conflict do nothing;
  -- Everyone in the group becomes friends with the newcomer, both ways.
  -- Follows that already exist keep where they came from.
  insert into public.follows (follower, followed, via_group)
  select p_user, m.user_id, true from public.group_members m where m.group_id = p_group and m.user_id <> p_user
  union all
  select m.user_id, p_user, true from public.group_members m where m.group_id = p_group and m.user_id <> p_user
  on conflict do nothing;
end $$;

-- Takes someone out of a group, and drops the follows joining made between
-- them and the rest of it, unless the two still share another group.
create or replace function public.leave_group_internal(p_group bigint, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from public.group_members where group_id = p_group and user_id = p_user;
  delete from public.follows f
   using public.group_members m
   where m.group_id = p_group
     and f.via_group
     and ((f.follower = p_user and f.followed = m.user_id) or (f.follower = m.user_id and f.followed = p_user))
     and not exists (select 1 from public.group_members a
                       join public.group_members b on b.group_id = a.group_id
                      where a.user_id = p_user and b.user_id = m.user_id);
end $$;

create or replace function public.leave_group(p_group bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  perform public.leave_group_internal(p_group, uid);
end $$;

create or replace function public.remove_member(p_group bigint, p_user uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  if not exists (select 1 from public.groups where id = p_group and created_by = uid) then
    raise exception 'Only the person who made the group can do that';
  end if;
  if p_user = uid then raise exception 'You can''t remove yourself. Leave the group instead'; end if;
  insert into public.group_removed (group_id, user_id) values (p_group, p_user) on conflict do nothing;
  perform public.leave_group_internal(p_group, p_user);
end $$;

create or replace function public.join_group(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); g public.groups;
begin
  select * into g from public.groups where invite_code = trim(p_code);
  if not found then raise exception 'That invite link doesn''t work any more'; end if;
  if not public.is_adult(uid) then raise exception 'Groups are for over-18s in this demo'; end if;
  if exists (select 1 from public.group_removed where group_id = g.id and user_id = uid) then
    raise exception 'You were removed from this group';
  end if;
  if (select count(*) from public.group_members where group_id = g.id) >= 50 then
    raise exception 'This group is full';
  end if;
  perform public.join_group_internal(g.id, uid);
  return json_build_object('id', g.id, 'name', g.name);
end $$;

-- ---------------------------------------------------------------------------
-- New answers: default visibility comes from app_config
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
  used json;
  ch record;
begin
  select * into q from public.questions
   where id = p_question and status = 'approved' and not is_event
     and (daily_date is null or daily_date <= public.today_uk());
  if not found then raise exception 'Question not found'; end if;
  is_daily := q.daily_date is not distinct from public.today_uk();

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
  if vis = 'public' and not public.is_adult(uid) then vis := 'friends'; end if;  -- under-18s never public

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
  challenged := exists (select 1 from public.challenges
                         where to_user = uid and question_id = p_question
                           and answered_at is null and expires_at > now());

  if not is_daily and not challenged
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 then
    raise exception 'That''s your answers for today. One is always kept for the daily question, so come back tomorrow';
  end if;

  insert into public.statements (user_id, question_id, value, visibility, via_challenge)
  values (uid, p_question, p_value, vis, challenged and not is_daily);

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

revoke execute on function public.knows(uuid), public.leave_group_internal(bigint, uuid),
  public.remove_member(bigint, uuid)
from public, anon, authenticated;
grant execute on function public.knows(uuid), public.remove_member(bigint, uuid) to authenticated;

notify pgrst, 'reload schema';

-- "Download my data" now includes everything held about you: your email,
-- groups, questions sent between you and friends, questions you suggested,
-- reports you made and feedback you sent, as the privacy notice says.
--
-- Safe to run twice.

create or replace function public.export_my_data() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'email', (select email from auth.users where id = auth.uid()),
    'profile', (select row_to_json(p) from public.profiles p where id = auth.uid()),
    'statements', (select coalesce(json_agg(s order by s.created_at), '[]') from public.statements s where user_id = auth.uid()),
    'predictions', (select coalesce(json_agg(p), '[]') from public.predictions p where user_id = auth.uid()),
    'credits', (select coalesce(json_agg(c order by c.created_at), '[]') from public.credit_ledger c where user_id = auth.uid()),
    'consents', (select coalesce(json_agg(c), '[]') from public.consents c where user_id = auth.uid()),
    'follows', (select coalesce(json_agg(f), '[]') from public.follows f where follower = auth.uid() or followed = auth.uid()),
    'groups', (select coalesce(json_agg(json_build_object('name', g.name, 'joined_at', m.joined_at,
                                                          'made_by_you', g.created_by = auth.uid())), '[]')
                 from public.group_members m join public.groups g on g.id = m.group_id where m.user_id = auth.uid()),
    'questions_sent', (select coalesce(json_agg(c order by c.created_at), '[]') from public.challenges c
                        where from_user = auth.uid() or to_user = auth.uid()),
    'suggested_questions', (select coalesce(json_agg(json_build_object('text', q.text, 'status', q.status,
                                                                       'created_at', q.created_at)), '[]')
                              from public.questions q where created_by = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

-- Avatars: each person can pick one of the pixel avatars (Cap, Specs,
-- Pigtails, Owl, Frog, Fox, each in red or green). Stored as '<sprite>-<tone>',
-- e.g. 'frog-green', matching the app's image names. Null = not picked yet.
-- Anyone who can see your name sees your avatar.
--
-- Safe to run twice.

alter table public.profiles add column if not exists avatar text
  check (avatar ~ '^[a-z]{2,16}-[a-z]{2,10}$');
grant select (avatar) on public.profiles to authenticated;

create or replace function public.set_avatar(p_avatar text) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile();
begin
  update public.profiles set avatar = nullif(lower(trim(p_avatar)), '') where id = uid;
exception
  when check_violation then raise exception 'Pick one of the avatars';
end $$;

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = '' as $$
  with used as (select public.answers_used_today(auth.uid()) as u)
  select json_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'avatar', p.avatar,
    'is_adult', public.is_adult(p.id),
    'sensitive_opt_in', p.sensitive_opt_in_at is not null,
    'credits', coalesce((select sum(amount) from public.credit_ledger where user_id = p.id), 0),
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

create or replace function public.profile_card(p_handle text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'id', p.id,
    'handle', p.handle, 'display_name', p.display_name, 'avatar', p.avatar,
    'is_friend', public.are_friends(auth.uid(), p.id),
    'i_follow', exists (select 1 from public.follows where follower = auth.uid() and followed = p.id),
    'follows_me', exists (select 1 from public.follows where follower = p.id and followed = auth.uid()),
    'predictions', public.hit_rate(p.id),
    'joined', p.created_at)
  from public.profiles p where p.handle = lower(p_handle)
$$;

create or replace function public.group_board(p_group bigint) returns json
language plpgsql stable security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); result json;
begin
  if not public.is_group_member(p_group) then raise exception 'You''re not in that group'; end if;
  select coalesce(json_agg(b order by b.last_at desc), '[]') into result from (
    select s.question_id,
           count(*) as answered,
           max(s.created_at) as last_at,
           case when bool_or(s.user_id = uid) then
             json_agg(json_build_object('handle', p.handle, 'name', p.display_name, 'avatar', p.avatar,
                                        'value', s.value, 'me', s.user_id = uid)
                      order by (s.user_id = uid) desc, p.display_name)
           end as answers
      from public.statements s
      join public.group_members gm on gm.user_id = s.user_id and gm.group_id = p_group
      join public.profiles p on p.id = s.user_id
     where s.superseded_at is null
       and (s.user_id = uid
            or (s.visibility in ('public', 'friends') and (s.hidden_until is null or s.hidden_until < now())))
     group by s.question_id) b;
  return result;
end $$;

-- Its result gains a column, so it is dropped and made again.
drop function if exists public.friends_answers(bigint);
create function public.friends_answers(p_question bigint)
returns table (handle text, display_name text, value boolean, avatar text)
language sql stable security definer set search_path = '' as $$
  select p.handle, p.display_name, s.value, p.avatar
    from public.statements s
    join public.profiles p on p.id = s.user_id
   where s.question_id = p_question and s.superseded_at is null
     and (s.hidden_until is null or s.hidden_until < now())
     and s.visibility in ('public', 'friends')
     and public.are_friends(auth.uid(), s.user_id)
     and exists (select 1 from public.statements m
                  where m.user_id = auth.uid() and m.question_id = p_question and m.superseded_at is null)
$$;

revoke execute on function public.set_avatar(text), public.friends_answers(bigint) from public, anon;
grant execute on function public.set_avatar(text), public.friends_answers(bigint) to authenticated;

notify pgrst, 'reload schema';

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

-- Stars: mark questions in the Questions tab and they're dealt into your
-- Today hand first. Only you can see your own stars, and they're part of
-- "Download my data".
--
-- Safe to run twice.

create table if not exists public.stars (
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, question_id)
);
alter table public.stars enable row level security;
drop policy if exists "own stars" on public.stars;
create policy "own stars" on public.stars for select to authenticated using (user_id = auth.uid());

create or replace function public.set_star(p_question bigint, p_on boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions;
begin
  if p_on then
    select * into q from public.questions where id = p_question;
    if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
    insert into public.stars (user_id, question_id) values (uid, p_question) on conflict do nothing;
  else
    delete from public.stars where user_id = uid and question_id = p_question;
  end if;
end $$;
revoke execute on function public.set_star(bigint, boolean) from public, anon;
grant execute on function public.set_star(bigint, boolean) to authenticated;

create or replace function public.export_my_data() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'email', (select email from auth.users where id = auth.uid()),
    'profile', (select row_to_json(p) from public.profiles p where id = auth.uid()),
    'statements', (select coalesce(json_agg(s order by s.created_at), '[]') from public.statements s where user_id = auth.uid()),
    'predictions', (select coalesce(json_agg(p), '[]') from public.predictions p where user_id = auth.uid()),
    'credits', (select coalesce(json_agg(c order by c.created_at), '[]') from public.credit_ledger c where user_id = auth.uid()),
    'consents', (select coalesce(json_agg(c), '[]') from public.consents c where user_id = auth.uid()),
    'follows', (select coalesce(json_agg(f), '[]') from public.follows f where follower = auth.uid() or followed = auth.uid()),
    'groups', (select coalesce(json_agg(json_build_object('name', g.name, 'joined_at', m.joined_at,
                                                          'made_by_you', g.created_by = auth.uid())), '[]')
                 from public.group_members m join public.groups g on g.id = m.group_id where m.user_id = auth.uid()),
    'questions_sent', (select coalesce(json_agg(c order by c.created_at), '[]') from public.challenges c
                        where from_user = auth.uid() or to_user = auth.uid()),
    'suggested_questions', (select coalesce(json_agg(json_build_object('text', q.text, 'status', q.status,
                                                                       'for', q.audience, 'created_at', q.created_at)), '[]')
                              from public.questions q where created_by = auth.uid()),
    'starred_questions', (select coalesce(json_agg(json_build_object('text', q.text, 'starred_at', s.created_at)
                                                   order by s.created_at), '[]')
                            from public.stars s join public.questions q on q.id = s.question_id where s.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

notify pgrst, 'reload schema';

-- Friend questions cost 3 slashes to make, however many friends you send them
-- to, and passing one on to more friends is free (for the writer and for
-- anyone who got it). Sending a question from the public bank still costs 2.
--
-- Safe to run twice.

create or replace function public.send_challenge(p_handle text, p_question bigint, p_minutes int default 1440)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); target uuid; bal int; cost int;
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

  -- Passing on a question written for friends is free.
  cost := case when exists (select 1 from public.questions where id = p_question and audience = 'friends')
               then 0 else public.cfg('send_cost') end;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < cost then raise exception 'Sending costs % slashes', cost; end if;

  insert into public.challenges (from_user, to_user, question_id, expires_at)
  values (uid, target, p_question, now() + make_interval(mins => p_minutes));
  if cost > 0 then
    insert into public.credit_ledger (user_id, amount, reason, question_id)
    values (uid, -cost, 'send', p_question);
  end if;
exception when unique_violation then
  raise exception 'You already sent them that question';
end $$;

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

  cost := public.cfg('friend_question_cost');
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

notify pgrst, 'reload schema';

-- Share a question you wrote as a link (?q=CODE). Anyone with the link sees
-- the question on the sign-up page, and once signed in can answer it, even if
-- it was written for friends and they aren't friends with the writer yet.
-- A question for friends can now be made without sending it to anyone, to
-- share only by link.
--
-- Safe to run twice.

-- One link per question, made the first time its writer shares it. Only the
-- functions below read this table.
create table if not exists public.question_links (
  question_id bigint primary key references public.questions (id) on delete cascade,
  code text not null unique default substr(md5(random()::text || clock_timestamp()::text), 1, 10),
  created_at timestamptz not null default now()
);
alter table public.question_links enable row level security;

-- Who opened a link: that's what lets them see a friends-only question.
create table if not exists public.question_link_opens (
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  opened_at timestamptz not null default now(),
  primary key (user_id, question_id)
);
alter table public.question_link_opens enable row level security;
drop policy if exists "own link opens" on public.question_link_opens;
create policy "own link opens" on public.question_link_opens for select to authenticated using (user_id = auth.uid());

create or replace function public.can_see_question(p_user uuid, q public.questions) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when q.created_by = p_user then true
    when q.audience = 'friends' then
      q.status = 'approved' and (public.are_friends(p_user, q.created_by)
        or exists (select 1 from public.challenges where to_user = p_user and question_id = q.id)
        or exists (select 1 from public.question_link_opens where user_id = p_user and question_id = q.id))
    else q.status = 'approved' and (q.daily_date is null or q.daily_date <= public.today_uk())
      and (q.sensitivity <> 'sensitive' or public.is_adult(p_user))
  end
$$;

-- The link for a question you wrote.
create or replace function public.share_question(p_question bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); c text;
begin
  if not exists (select 1 from public.questions where id = p_question and created_by = uid and status <> 'rejected') then
    raise exception 'You can only share questions you wrote';
  end if;
  insert into public.question_links (question_id) values (p_question) on conflict do nothing;
  select code into c from public.question_links where question_id = p_question;
  return c;
end $$;

-- Shown on the sign-up page, so it works signed out.
create or replace function public.question_preview(p_code text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object('text', q.text, 'by', p.display_name, 'live', q.status = 'approved')
    from public.question_links l
    join public.questions q on q.id = l.question_id and q.status <> 'rejected'
    left join public.profiles p on p.id = q.created_by
   where l.code = trim(p_code)
$$;

-- Opening a link once signed in: the question becomes yours to answer.
create or replace function public.open_question_link(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions;
begin
  select qq.* into q from public.question_links l join public.questions qq on qq.id = l.question_id
   where l.code = trim(p_code);
  if not found or q.status = 'rejected' then raise exception 'That question link doesn''t work any more'; end if;
  if q.status <> 'approved' then raise exception 'That question is still waiting for a moderator'; end if;
  if q.audience = 'friends' and q.created_by is distinct from uid then
    insert into public.question_link_opens (user_id, question_id) values (uid, q.id) on conflict do nothing;
  end if;
  return json_build_object('id', q.id, 'by_id', q.created_by,
    'by', (select display_name from public.profiles where id = q.created_by),
    'friends', q.created_by = uid or public.are_friends(uid, q.created_by),
    'following', exists (select 1 from public.follows where follower = uid and followed = q.created_by));
end $$;

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

  cost := public.cfg('friend_question_cost');
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

create or replace function public.export_my_data() returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'email', (select email from auth.users where id = auth.uid()),
    'profile', (select row_to_json(p) from public.profiles p where id = auth.uid()),
    'statements', (select coalesce(json_agg(s order by s.created_at), '[]') from public.statements s where user_id = auth.uid()),
    'predictions', (select coalesce(json_agg(p), '[]') from public.predictions p where user_id = auth.uid()),
    'credits', (select coalesce(json_agg(c order by c.created_at), '[]') from public.credit_ledger c where user_id = auth.uid()),
    'consents', (select coalesce(json_agg(c), '[]') from public.consents c where user_id = auth.uid()),
    'follows', (select coalesce(json_agg(f), '[]') from public.follows f where follower = auth.uid() or followed = auth.uid()),
    'groups', (select coalesce(json_agg(json_build_object('name', g.name, 'joined_at', m.joined_at,
                                                          'made_by_you', g.created_by = auth.uid())), '[]')
                 from public.group_members m join public.groups g on g.id = m.group_id where m.user_id = auth.uid()),
    'questions_sent', (select coalesce(json_agg(c order by c.created_at), '[]') from public.challenges c
                        where from_user = auth.uid() or to_user = auth.uid()),
    'suggested_questions', (select coalesce(json_agg(json_build_object('text', q.text, 'status', q.status,
                                                                       'for', q.audience, 'created_at', q.created_at)), '[]')
                              from public.questions q where created_by = auth.uid()),
    'starred_questions', (select coalesce(json_agg(json_build_object('text', q.text, 'starred_at', s.created_at)
                                                   order by s.created_at), '[]')
                            from public.stars s join public.questions q on q.id = s.question_id where s.user_id = auth.uid()),
    'questions_opened_from_links', (select coalesce(json_agg(json_build_object('text', q.text, 'opened_at', o.opened_at)
                                                             order by o.opened_at), '[]')
                                      from public.question_link_opens o join public.questions q on q.id = o.question_id
                                     where o.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.share_question(bigint), public.open_question_link(text) from public, anon;
revoke execute on function public.question_preview(text) from public;
grant execute on function public.share_question(bigint), public.open_question_link(text) to authenticated;
grant execute on function public.question_preview(text) to anon, authenticated;

notify pgrst, 'reload schema';

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

-- 60 launch questions (same bank as the clickable prototype).
-- Launch day is the day you run this: "Is the Earth flat?" goes live today,
-- then one week-one question a day. After that ensure_daily() keeps the
-- slot filled from the rest of the bank.
insert into public.questions (text, category, sensitivity, option_yes, option_no, emoji_yes, emoji_no, partner, daily_date) values
  ('Is the Earth flat?', 'Big debates', 'standard', null, null, null, null, null, public.today_uk() + 0),
  ('Nike or Reebok?', 'Brands', 'standard', 'Nike', 'Reebok', '✔️', '🇬🇧', null, public.today_uk() + 5),
  ('Can you run 5k?', 'Fitness', 'personal', null, null, null, null, 'Strava', null),
  ('Is a hot dog a sandwich?', 'Food', 'standard', null, null, null, null, null, public.today_uk() + 1),
  ('Beach or mountains?', 'Lifestyle', 'standard', 'Beach', 'Mountains', '🏖️', '🏔️', null, null),
  ('Is it OK to recline your seat on a plane?', 'Ethics', 'standard', null, null, null, null, null, public.today_uk() + 3),
  ('Should pineapple go on pizza?', 'Food', 'standard', null, null, null, null, null, public.today_uk() + 4),
  ('Did humans really land on the Moon in 1969?', 'Big debates', 'standard', null, null, null, null, null, null),
  ('iPhone or Android?', 'Brands', 'standard', 'iPhone', 'Android', '🍎', '🤖', null, null),
  ('Coke or Pepsi?', 'Brands', 'standard', 'Coke', 'Pepsi', '🔴', '🔵', null, null),
  ('Adidas or Puma?', 'Brands', 'standard', 'Adidas', 'Puma', '⛰️', '🐆', null, null),
  ('Tea or coffee?', 'Food', 'standard', 'Tea', 'Coffee', '🍵', '☕', null, null),
  ('Would you pay more for a brand that never sells your data?', 'Brands', 'standard', null, null, null, null, null, null),
  ('McDonald''s or Burger King?', 'Brands', 'standard', 'McDonald''s', 'Burger King', '🍟', '👑', null, null),
  ('Have you run a half marathon?', 'Fitness', 'personal', null, null, null, null, 'Strava', null),
  ('Have you cycled 50 km in one ride?', 'Fitness', 'personal', null, null, null, null, 'Strava', null),
  ('Do you exercise three or more times a week?', 'Fitness', 'personal', null, null, null, null, 'Strava', null),
  ('Can you swim 1 km without stopping?', 'Fitness', 'personal', null, null, null, null, 'Strava', null),
  ('Do you walk 10,000 steps on most days?', 'Fitness', 'personal', null, null, null, null, 'Apple Health', null),
  ('Do you sleep seven hours or more most nights?', 'Lifestyle', 'personal', null, null, null, null, 'Apple Health', null),
  ('Early bird or night owl?', 'Lifestyle', 'standard', 'Early bird', 'Night owl', '🐦', '🦉', null, null),
  ('Do you want children one day?', 'Dating', 'personal', null, null, null, null, null, null),
  ('Do you believe in love at first sight?', 'Dating', 'standard', null, null, null, null, null, null),
  ('Should you split the bill on a first date?', 'Dating', 'standard', null, null, null, null, null, null),
  ('Would you date someone who places bets?', 'Dating', 'standard', null, null, null, null, null, null),
  ('Would you move country for a partner?', 'Dating', 'standard', null, null, null, null, null, null),
  ('Cats or dogs?', 'Lifestyle', 'standard', 'Cats', 'Dogs', '🐱', '🐶', null, public.today_uk() + 6),
  ('Are you vegetarian or vegan?', 'Food', 'personal', null, null, null, null, null, null),
  ('Do you drink alcohol?', 'Lifestyle', 'personal', null, null, null, null, null, null),
  ('Do you smoke or vape?', 'Lifestyle', 'personal', null, null, null, null, null, null),
  ('Do you believe in God?', 'Beliefs', 'sensitive', null, null, null, null, null, null),
  ('Do you pray regularly?', 'Beliefs', 'sensitive', null, null, null, null, null, null),
  ('Do you believe in life after death?', 'Beliefs', 'sensitive', null, null, null, null, null, null),
  ('Should the UK rejoin the EU?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Should the monarchy be abolished?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Did you vote in the last general election?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Should voting be compulsory?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Should cannabis be legal in the UK?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Should the UK bring back the death penalty?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Do you support a universal basic income?', 'Politics', 'sensitive', null, null, null, null, null, null),
  ('Would you return a lost wallet with the cash still inside?', 'Ethics', 'standard', null, null, null, null, null, null),
  ('Have you ever cheated at a board game?', 'Ethics', 'standard', null, null, null, null, null, null),
  ('Would you tell a friend their partner was cheating?', 'Ethics', 'standard', null, null, null, null, null, null),
  ('Is it OK to lie on your CV?', 'Ethics', 'standard', null, null, null, null, null, null),
  ('Would you bet against your own team?', 'Ethics', 'standard', null, null, null, null, null, null),
  ('Do you save money every month?', 'Money', 'personal', null, null, null, null, null, null),
  ('Do you own any crypto?', 'Money', 'personal', null, null, null, null, null, null),
  ('Have you placed a bet in the last year?', 'Money', 'personal', null, null, null, null, null, null),
  ('Rent or buy your home?', 'Money', 'standard', 'Rent', 'Buy', '🏢', '🏡', null, null),
  ('Will AI be able to do your job within ten years?', 'Tech', 'standard', null, null, null, null, null, null),
  ('Do you check your phone within five minutes of waking up?', 'Tech', 'standard', null, null, null, null, null, null),
  ('Should under-16s be banned from social media?', 'Tech', 'standard', null, null, null, null, null, null),
  ('Work from home or the office?', 'Tech', 'standard', 'Home', 'Office', '🏠', '🏙️', null, null),
  ('Would you ride in a self-driving car today?', 'Tech', 'standard', null, null, null, null, null, null),
  ('Do aliens exist?', 'Wild cards', 'standard', null, null, null, null, null, null),
  ('Would you want to know the date you''ll die?', 'Wild cards', 'standard', null, null, null, null, null, null),
  ('Would you take a one-way ticket to Mars?', 'Big debates', 'standard', null, null, null, null, null, public.today_uk() + 2),
  ('Is time travel possible?', 'Wild cards', 'standard', null, null, null, null, null, null),
  ('Can you do 20 push-ups in a row?', 'Fitness', 'personal', null, null, null, null, null, null),
  ('Have you lived in another country?', 'Lifestyle', 'standard', null, null, null, null, null, null);

-- World events for the Predict tab. Settle them with resolve_event(id, outcome).
insert into public.questions (text, category, is_event, closes_at) values
  ('Will it snow in London on Christmas Day 2026?', 'World events', true, '2026-12-24 23:59:00+00'),
  ('Will a crewed mission land on the Moon before 2028?', 'World events', true, '2027-12-31 23:59:00+00');
