-- yeah/nah demo: every update since friend groups, in one paste.
-- For a database set up before 2026-10-10. It is the 18+ and themed questions
-- update, then the privacy fixes (supabase/migrations/20261010* and 20261011*).
-- Safe to run more than once, so it doesn't matter if you ran the first part already.

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
