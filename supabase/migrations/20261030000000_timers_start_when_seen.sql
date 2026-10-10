-- A question a friend sends you is on the clock only from the first time it's
-- on your screen, not from when it was sent. Until then the challenge keeps
-- its length in minutes and expires_at is 'infinity', so it can't run out and
-- answering it still counts as in time. The app calls see_question when the
-- card is on screen. Answering it, or using Overtime on it, starts it too.
--
-- Every way of sending (send_challenge, make_friend_question) still writes
-- expires_at as now() + the minutes picked; a trigger turns that into the
-- minutes and 'infinity', so none of them change here.
--
-- Safe to run twice.

alter table public.challenges add column if not exists minutes int;
alter table public.challenges add column if not exists seen_at timestamptz;

-- Challenges already sent: answered or run-out ones keep their times. Ones
-- still open get their whole time again from the next time they're seen.
update public.challenges set
  minutes = greatest(1, round(extract(epoch from expires_at - created_at) / 60))::int,
  seen_at = case when answered_at is not null or expires_at <= now() then created_at end,
  expires_at = case when answered_at is null and expires_at > now() then 'infinity' else expires_at end
 where minutes is null;

create or replace function public.challenge_timer() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    if new.seen_at is null and new.answered_at is null then
      new.minutes := coalesce(new.minutes, greatest(1, round(extract(epoch from new.expires_at - now()) / 60))::int);
      new.expires_at := 'infinity';
    end if;
  elsif new.seen_at is null and new.answered_at is not null then
    -- Answered before the app said it was on screen: it was seen then.
    new.seen_at := new.answered_at;
    if new.expires_at = 'infinity' then new.expires_at := new.answered_at + make_interval(mins => new.minutes); end if;
  end if;
  return new;
end $$;
drop trigger if exists challenge_timer on public.challenges;
create trigger challenge_timer before insert or update on public.challenges
  for each row execute function public.challenge_timer();

-- Starts the timers on every friend's challenge to p_user for this question
-- that hasn't started yet. Returns how many started.
create or replace function public.start_timers(p_user uuid, p_question bigint) returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.challenges set seen_at = now(), expires_at = now() + make_interval(mins => minutes)
   where to_user = p_user and question_id = p_question and seen_at is null and answered_at is null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke execute on function public.start_timers(uuid, bigint), public.challenge_timer() from public, anon, authenticated;

-- The app calls this when a question's card is on your screen.
create or replace function public.see_question(p_question bigint) returns int
language sql security definer set search_path = '' as $$
  select public.start_timers(public.require_profile(), p_question)
$$;
grant execute on function public.see_question(bigint) to authenticated;

-- use_power(): Overtime on a question you haven't opened yet starts its timer
-- first, so the extra time isn't lost. Otherwise as in 20261023.
create or replace function public.use_power(p_kind text, p_question bigint default null, p_guess int default null, p_pick text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions; k public.powerup_kinds; pid bigint; nm text;
begin
  select name into nm from public.powerup_kinds where kind = p_kind and effect = p_kind;
  if nm is null then raise exception 'No such card'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));

  if p_kind in ('peek', 'mind_reader', 'overtime', 'called_it') then
    select * into q from public.questions where id = p_question;
    if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
    if exists (select 1 from public.statements where user_id = uid and question_id = p_question and superseded_at is null) then
      raise exception 'You''ve already answered that one';
    end if;
  end if;

  if p_kind in ('peek', 'mind_reader') then
    if not public.power_used_on(uid, p_kind, p_question) then
      if public.pocket_use(uid, p_kind, p_question) is null then raise exception 'You don''t have a % card', nm; end if;
    end if;
    if p_kind = 'peek' then return public.question_split(p_question); end if;
    return (select coalesce(json_agg(f), '[]') from public.friends_answers(p_question) f);

  elsif p_kind = 'overtime' then
    if not exists (select 1 from public.challenges where to_user = uid and question_id = p_question
                    and answered_at is null and expires_at > now()) then
      raise exception 'Overtime works on a question a friend sent you, before its timer runs out';
    end if;
    if public.pocket_use(uid, p_kind, p_question) is null then raise exception 'You don''t have an Overtime card'; end if;
    perform public.start_timers(uid, p_question);
    update public.challenges set expires_at = expires_at + make_interval(mins => public.cfg('overtime_minutes'))
     where to_user = uid and question_id = p_question and answered_at is null and expires_at > now();
    return json_build_object('expires_at', (select max(expires_at) from public.challenges
                                             where to_user = uid and question_id = p_question));

  elsif p_kind = 'called_it' then
    if q.daily_date is distinct from public.today_uk() then raise exception 'Called it works on today''s question'; end if;
    if p_guess is null or p_guess not between 0 and 100 then raise exception 'Guess a number from 0 to 100'; end if;
    if public.power_used_on(uid, p_kind, p_question) then raise exception 'You''ve already made your guess'; end if;
    pid := public.pocket_use(uid, p_kind, p_question);
    if pid is null then raise exception 'You don''t have a Called it card'; end if;
    update public.pocket set guess = p_guess where id = pid;
    return json_build_object('guess', p_guess);

  elsif p_kind = 'wildcard' then
    select * into k from public.powerup_kinds where kind = p_pick and effect is distinct from 'wildcard';
    if not found then raise exception 'Pick which card it becomes'; end if;
    pid := public.pocket_use(uid, p_kind, null);
    if pid is null then raise exception 'You don''t have a Wildcard'; end if;
    update public.pocket set became = k.kind where id = pid;
    if k.effect is not null then
      insert into public.pocket (user_id, kind, expires_on, used_at)
      values (uid, k.kind, public.today_uk(), case when k.effect = 'extra_hand' then now() end);
    elsif k.slashes > 0 then
      insert into public.credit_ledger (user_id, amount, reason) values (uid, k.slashes, 'powerup');
    end if;
    return json_build_object('kind', k.kind, 'name', k.name, 'slashes', k.slashes, 'effect', k.effect);
  end if;
  raise exception '% works by itself', nm;
end $$;

notify pgrst, 'reload schema';
