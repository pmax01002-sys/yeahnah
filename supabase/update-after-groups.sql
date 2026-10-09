-- yeah/nah demo: every update since friend groups, in one paste.
-- For a database set up before 2026-10-10. It is the 18+ and themed questions
-- update, the privacy fixes, the complete data download, avatars, slashes,
-- question costs with friend questions, stars, question links, the Future
-- unlock, power-up cards, unlimited slashes for the owner and the nightly
-- economy record (supabase/migrations/20261010* to 20261022*).
-- Safe to run more than once, so it doesn't matter if you ran part of it already.

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

-- Power-up cards. The first hand of the day sometimes includes one. For now
-- each power-up holds slashes to claim, and rarer ones hold more. Effect cards
-- can be added later as new rows in powerup_kinds.
--
--   powerup_chance (app_config): percent of days that come with a power-up.
--   powerup_kinds.weight: relative odds of each card when there is one.
--
-- Safe to run twice.

insert into public.app_config (key, value) values ('powerup_chance', 50) on conflict (key) do nothing;

create table if not exists public.powerup_kinds (
  kind text primary key,
  name text not null,
  rarity text not null check (rarity in ('common', 'uncommon', 'rare', 'epic', 'legendary')),
  weight int not null check (weight >= 0),
  slashes int not null default 0 check (slashes >= 0),
  blurb text not null
);
alter table public.powerup_kinds enable row level security;
drop policy if exists "read powerup kinds" on public.powerup_kinds;
create policy "read powerup kinds" on public.powerup_kinds for select to authenticated using (true);

insert into public.powerup_kinds (kind, name, rarity, weight, slashes, blurb) values
  ('loose_change', 'Loose change', 'common', 50, 1, 'Found down the back of the sofa.'),
  ('pocket_money', 'Pocket money', 'uncommon', 25, 2, 'Someone was feeling generous.'),
  ('lucky_find', 'Lucky find', 'rare', 15, 3, 'Was it there yesterday? Who knows.'),
  ('windfall', 'Windfall', 'epic', 8, 5, 'The wind blew in your direction for once.'),
  ('golden_slash', 'Golden slash', 'legendary', 2, 10, 'The rarest card in the deck.')
on conflict (kind) do nothing;

-- One row per person per UK day, made the first time the app asks. kind is
-- null on days without a power-up, so every device sees the same thing.
create table if not exists public.powerups (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  kind text references public.powerup_kinds (kind),
  claimed_at timestamptz,
  primary key (user_id, day)
);
alter table public.powerups enable row level security;
drop policy if exists "own powerups" on public.powerups;
create policy "own powerups" on public.powerups for select to authenticated using (user_id = auth.uid());

-- Read-only from the app: power-ups are only drawn and claimed by the functions below.
revoke all on public.powerups, public.powerup_kinds from anon;
revoke insert, update, delete on public.powerups, public.powerup_kinds from authenticated;

-- Today's power-up, if there is one. The odds are drawn once a day, server side.
create or replace function public.todays_powerup() returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); k text; p public.powerups;
begin
  select * into p from public.powerups where user_id = uid and day = public.today_uk();
  if not found then
    if random() * 100 < public.cfg('powerup_chance') then
      -- Weighted draw: the smallest -ln(u)/weight wins with odds weight/total.
      select kind into k from public.powerup_kinds where weight > 0 order by -ln(1 - random()) / weight limit 1;
    end if;
    insert into public.powerups (user_id, day, kind) values (uid, public.today_uk(), k) on conflict do nothing;
    select * into p from public.powerups where user_id = uid and day = public.today_uk();
  end if;
  if p.kind is null then return null; end if;
  return (select json_build_object('kind', k.kind, 'name', k.name, 'rarity', k.rarity, 'slashes', k.slashes,
                                   'blurb', k.blurb, 'claimed', p.claimed_at is not null,
                                   'odds', round(100.0 * k.weight / nullif((select sum(weight) from public.powerup_kinds), 0)))
            from public.powerup_kinds k where k.kind = p.kind);
end $$;

-- Claim today's power-up. Unclaimed ones are gone at midnight.
create or replace function public.claim_powerup() returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); k text; amount int;
begin
  update public.powerups set claimed_at = now()
   where user_id = uid and day = public.today_uk() and kind is not null and claimed_at is null
  returning kind into k;
  if k is null then raise exception 'There''s nothing to claim today'; end if;
  select slashes into amount from public.powerup_kinds where kind = k;
  if amount > 0 then
    insert into public.credit_ledger (user_id, amount, reason) values (uid, amount, 'powerup');
  end if;
  return amount;
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
    'power_ups', (select coalesce(json_agg(json_build_object('day', pu.day, 'card', k.name, 'slashes', k.slashes,
                                                            'claimed_at', pu.claimed_at) order by pu.day), '[]')
                    from public.powerups pu join public.powerup_kinds k on k.kind = pu.kind where pu.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.todays_powerup(), public.claim_powerup() from public, anon;
grant execute on function public.todays_powerup(), public.claim_powerup() to authenticated;

notify pgrst, 'reload schema';

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

-- A nightly record of the slash economy, to set slashtax's targets from real
-- numbers before any tax exists. It only reads: nobody's slashes change.
-- One row per UK day in economy_days, written just after midnight for the
-- day before, and filled in for every earlier day the first time it runs.
-- Read it in the Supabase table editor; the app never shows it.
-- Accounts with unlimited slashes (public.has_unlimited_slashes) are left out
-- of every number, so the owner's testing doesn't skew them.
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
     and not public.has_unlimited_slashes(p.id)
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
         (select coalesce(sum(amount), 0) from public.credit_ledger
           where amount > 0 and created_at >= d0 and created_at < d1 and not public.has_unlimited_slashes(user_id)),
         (select coalesce(-sum(amount), 0) from public.credit_ledger
           where amount < 0 and created_at >= d0 and created_at < d1 and not public.has_unlimited_slashes(user_id)),
         coalesce(sum(b.bal), 0),
         coalesce(percentile_cont(0.5) within group (order by b.bal), 0),
         coalesce(percentile_cont(0.9) within group (order by b.bal), 0),
         count(*) filter (where b.bal > public.cfg('slashtax_allowance')),
         round(s, 3), round(g, 3), round(vv, 2), manual
    from (select p.id, coalesce((select sum(amount) from public.credit_ledger c
                                  where c.user_id = p.id and c.created_at < d1), 0) as bal
            from public.profiles p where p.created_at < d1 and not public.has_unlimited_slashes(p.id)) b
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
