-- yeah/nah demo: every update since friend groups, in one paste.
-- For a database set up before 2026-10-10. It is the 18+ and themed questions
-- update, the privacy fixes, the complete data download, avatars, slashes,
-- question costs with friend questions, stars, question links, the Future
-- unlock, power-up and effect cards, unlimited slashes for the owner,
-- friend requests from question links, the admin area, the daily question
-- in the admin area, sharing any question as a link, Hot ones and answering
-- from a link before signing up (supabase/migrations/20261010* to 20261029*).
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

-- Effect cards: power-ups that do something instead of holding slashes. They
-- come from the same daily draw as the slash cards, one tier of rarity each.
-- Claiming one ("Keep it") puts it in your pocket until midnight (Wildcard:
-- 7 days), and it's used from the question it works on:
--
--   Second thoughts  common     an extra change of mind today (used when you change an answer)
--   Free post        common     your next send is free, even to a whole group
--   Peek             uncommon   see the crowd split on a question before answering
--   Overtime         uncommon   an extra hour on a question a friend sent you
--   Mind reader      rare       see how friends answered a question before answering
--   Extra hand       rare       3 more cards today, with 3 more answers (used straight away)
--   Called it        epic       guess today's split before voting: within 5 points wins 10 slashes
--   Wildcard         legendary  turns into any other card you pick
--
-- Every effect is checked here on the server. Settings in app_config:
--   called_it_prize 10, called_it_window 5, called_it_min_answers 3,
--   overtime_minutes 60, extra_hand_cards 3, free_post_minutes 5.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('called_it_prize', 10), ('called_it_window', 5), ('called_it_min_answers', 3),
  ('overtime_minutes', 60), ('extra_hand_cards', 3), ('free_post_minutes', 5)
on conflict (key) do nothing;

alter table public.powerup_kinds add column if not exists effect text;                 -- null for slash cards
alter table public.powerup_kinds add column if not exists keeps_days int not null default 1;  -- 1 = until midnight

-- Make room for the effect cards: each rarity keeps its share of the draw
-- (50/25/15/8/2), now split between slash and effect cards. Only weights
-- still at their first values change, so tuned ones are left alone.
update public.powerup_kinds k set weight = v.new
  from (values ('loose_change', 50, 20), ('pocket_money', 25, 9), ('lucky_find', 15, 5),
               ('windfall', 8, 4), ('golden_slash', 2, 1)) v (kind, old, new)
 where k.kind = v.kind and k.weight = v.old
   and not exists (select 1 from public.powerup_kinds where effect is not null);

insert into public.powerup_kinds (kind, name, rarity, weight, slashes, blurb, effect, keeps_days) values
  ('second_thoughts', 'Second thoughts', 'common', 15, 0, 'Everyone deserves one more go.', 'second_thoughts', 1),
  ('free_post', 'Free post', 'common', 15, 0, 'First class, no stamp.', 'free_post', 1),
  ('peek', 'Peek', 'uncommon', 8, 0, 'Just a little look.', 'peek', 1),
  ('overtime', 'Overtime', 'uncommon', 8, 0, 'The ref has added time.', 'overtime', 1),
  ('mind_reader', 'Mind reader', 'rare', 5, 0, 'You had a feeling.', 'mind_reader', 1),
  ('extra_hand', 'Extra hand', 'rare', 5, 0, 'Deal me in.', 'extra_hand', 1),
  ('called_it', 'Called it', 'epic', 4, 0, 'Trust your gut.', 'called_it', 1),
  ('wildcard', 'Wildcard', 'legendary', 1, 0, 'The joker in the pack.', 'wildcard', 7)
on conflict (kind) do nothing;

-- Kept effect cards. A row is used once used_at is set; question_id is what it
-- was used on. Called it keeps the guess, the real split and what it won.
create table if not exists public.pocket (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null references public.powerup_kinds (kind),
  got_at timestamptz not null default now(),
  expires_on date not null,                 -- the last UK day it can be used
  used_at timestamptz,
  question_id bigint references public.questions (id) on delete set null,
  guess int,                                -- Called it: % yeah guessed
  result int,                               -- Called it: % yeah among everyone else
  won int,                                  -- Called it: slashes won
  became text references public.powerup_kinds (kind)  -- Wildcard: the card picked
);
create index if not exists pocket_user on public.pocket (user_id, expires_on);
alter table public.pocket enable row level security;
drop policy if exists "own pocket" on public.pocket;
create policy "own pocket" on public.pocket for select to authenticated using (user_id = auth.uid());
revoke all on public.pocket from anon;
revoke insert, update, delete on public.pocket from authenticated;

-- Use the card that runs out soonest. Returns its id, or null if there isn't one.
create or replace function public.pocket_use(p_user uuid, p_effect text, p_question bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare pid bigint;
begin
  select pk.id into pid from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
   where pk.user_id = p_user and k.effect = p_effect and pk.used_at is null and pk.expires_on >= public.today_uk()
   order by pk.expires_on, pk.id limit 1
   for update of pk;
  if pid is not null then
    update public.pocket set used_at = now(), question_id = p_question where id = pid;
  end if;
  return pid;
end $$;

create or replace function public.power_used_on(p_user uuid, p_effect text, p_question bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                  where pk.user_id = p_user and k.effect = p_effect and pk.question_id = p_question
                    and pk.used_at is not null)
$$;

-- What today's cards add: answers from Extra hand, and changes of mind from
-- Second thoughts (both used today and still in your pocket).
create or replace function public.power_bonus(p_user uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'answers', public.cfg('extra_hand_cards') * count(*) filter (where k.effect = 'extra_hand' and pk.used_at >= public.uk_day_start()),
    'changes', count(*) filter (where k.effect = 'second_thoughts'
                                  and (pk.used_at >= public.uk_day_start() or (pk.used_at is null and pk.expires_on >= public.today_uk()))),
    'changes_used', count(*) filter (where k.effect = 'second_thoughts' and pk.used_at >= public.uk_day_start()))
  from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
  where pk.user_id = p_user
$$;

-- Today's power-up, now saying whether it's an effect card.
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
                                   'blurb', k.blurb, 'effect', k.effect, 'keeps_days', k.keeps_days,
                                   'claimed', p.claimed_at is not null,
                                   'odds', round(100.0 * k.weight / nullif((select sum(weight) from public.powerup_kinds), 0)))
            from public.powerup_kinds k where k.kind = p.kind);
end $$;

-- Claim today's power-up: slashes go to your balance, effect cards to your
-- pocket. Extra hand is used as soon as it's kept. Returns the slashes added.
create or replace function public.claim_powerup() returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); kk text; k public.powerup_kinds;
begin
  update public.powerups set claimed_at = now()
   where user_id = uid and day = public.today_uk() and kind is not null and claimed_at is null
  returning kind into kk;
  if kk is null then raise exception 'There''s nothing to claim today'; end if;
  select * into k from public.powerup_kinds where kind = kk;
  if k.effect is not null then
    insert into public.pocket (user_id, kind, expires_on, used_at)
    values (uid, kk, public.today_uk() + greatest(k.keeps_days, 1) - 1, case when k.effect = 'extra_hand' then now() end);
    return 0;
  end if;
  if k.slashes > 0 then
    insert into public.credit_ledger (user_id, amount, reason) values (uid, k.slashes, 'powerup');
  end if;
  return k.slashes;
end $$;

-- Peek and Mind reader open these up before you've answered.
create or replace function public.question_split(p_question bigint) returns json
language sql stable security definer set search_path = '' as $$
  select case when exists (
      select 1 from public.statements
       where user_id = auth.uid() and question_id = p_question and superseded_at is null)
      or public.power_used_on(auth.uid(), 'peek', p_question)
    then (select json_build_object(
            'yes', count(*) filter (where value),
            'no', count(*) filter (where not value),
            'total', count(*))
          from public.statements
         where question_id = p_question and superseded_at is null)
    else null end
$$;

create or replace function public.friends_answers(p_question bigint)
returns table (handle text, display_name text, value boolean, avatar text)
language sql stable security definer set search_path = '' as $$
  select p.handle, p.display_name, s.value, p.avatar
    from public.statements s
    join public.profiles p on p.id = s.user_id
   where s.question_id = p_question and s.superseded_at is null
     and (s.hidden_until is null or s.hidden_until < now())
     and s.visibility in ('public', 'friends')
     and public.are_friends(auth.uid(), s.user_id)
     and (exists (select 1 from public.statements m
                   where m.user_id = auth.uid() and m.question_id = p_question and m.superseded_at is null)
          or public.power_used_on(auth.uid(), 'mind_reader', p_question))
$$;

-- Called it pays out when you answer today's question, against how everyone
-- else answered. With too few other answers to call, the card comes back and
-- keeps until tomorrow.
create or replace function public.settle_called_it(p_user uuid, p_question bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; yes int; total int; pct int; prize int;
begin
  for r in select pk.id, pk.guess from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
            where pk.user_id = p_user and k.effect = 'called_it' and pk.question_id = p_question
              and pk.used_at is not null and pk.won is null
            for update of pk
  loop
    select count(*) filter (where value), count(*) into yes, total from public.statements
     where question_id = p_question and superseded_at is null and user_id <> p_user;
    if total < public.cfg('called_it_min_answers') then
      update public.pocket set used_at = null, question_id = null, guess = null,
             expires_on = greatest(expires_on, public.today_uk() + 1)
       where id = r.id;
    else
      pct := round(100.0 * yes / total);
      prize := case when abs(pct - r.guess) <= public.cfg('called_it_window') then public.cfg('called_it_prize') else 0 end;
      update public.pocket set result = pct, won = prize where id = r.id;
      if prize > 0 then
        insert into public.credit_ledger (user_id, amount, reason, question_id) values (p_user, prize, 'powerup', p_question);
      end if;
    end if;
  end loop;
end $$;

-- Use a card from your pocket on a question. Peek and Mind reader return what
-- they show (and showing it again on the same question is free).
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

-- answer(): Second thoughts allow another change of mind, Extra hand adds
-- answers, and answering today's question settles Called it.
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
  bonus json;
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
  bonus := public.power_bonus(uid);

  if had then
    if cur.verified then raise exception 'This answer was verified by %; change it there', cur.source; end if;
    if (used->>'changes')::int >= public.cfg('changes_per_day') + (bonus->>'changes_used')::int then
      if public.pocket_use(uid, 'second_thoughts', p_question) is null then
        raise exception 'You have used today''s change of mind';
      end if;
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
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 + (bonus->>'answers')::int then
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

  if is_daily then perform public.settle_called_it(uid, p_question); end if;

  return public.question_split(p_question);
end $$;

-- Free post: the next send that would cost slashes is free, and so is sending
-- the same question to anyone else in the next few minutes (a whole group).
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
  if cost > 0 then
    if exists (select 1 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                where pk.user_id = uid and k.effect = 'free_post' and pk.question_id = p_question
                  and pk.used_at > now() - make_interval(mins => public.cfg('free_post_minutes'))) then
      cost := 0;
    elsif public.pocket_use(uid, 'free_post', p_question) is not null then
      cost := 0;
    end if;
  end if;
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

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = '' as $$
  with used as (select public.answers_used_today(auth.uid()) as u, public.power_bonus(auth.uid()) as b)
  select json_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'avatar', p.avatar,
    'is_adult', public.is_adult(p.id),
    'sensitive_opt_in', p.sensitive_opt_in_at is not null,
    'credits', coalesce((select sum(amount) from public.credit_ledger where user_id = p.id), 0),
    'unlimited', public.has_unlimited_slashes(p.id),
    'daily_done', (u->>'daily_done')::boolean,
    -- one of the five is always kept for the daily question; Extra hand adds more
    'answers_left_today', public.cfg('answers_per_day') + (b->>'answers')::int - (u->>'others')::int
                          - case when (u->>'daily_done')::boolean then 1 else 0 end,
    'other_answers_left_today', public.cfg('answers_per_day') + (b->>'answers')::int - 1 - (u->>'others')::int,
    'changes_left_today', public.cfg('changes_per_day') + (b->>'changes')::int - (u->>'changes')::int,
    'predictions', public.hit_rate(p.id),
    'created_at', p.created_at)
  from public.profiles p, used where p.id = auth.uid()
$$;

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
    'pocket', (select coalesce(json_agg(json_build_object('card', k.name, 'got_at', pk.got_at, 'used_at', pk.used_at,
                                                         'used_on', q.text, 'guess', pk.guess, 'result', pk.result,
                                                         'won', pk.won, 'became', pk.became) order by pk.got_at), '[]')
                 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                 left join public.questions q on q.id = pk.question_id
                where pk.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.pocket_use(uuid, text, bigint), public.power_used_on(uuid, text, bigint),
  public.power_bonus(uuid), public.settle_called_it(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.use_power(text, bigint, int, text) from public, anon;
grant execute on function public.use_power(text, bigint, int, text) to authenticated;

notify pgrst, 'reload schema';

-- Opening someone's question link sends them a friend request: the person
-- who shared it sees you under "Want to be friends" with Follow back. It only
-- happens the first time you open that link, so if you undo it, opening the
-- link again doesn't send it again.
--
-- Safe to run twice.

create or replace function public.open_question_link(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions; first_open boolean := false; requested boolean := false;
begin
  select qq.* into q from public.question_links l join public.questions qq on qq.id = l.question_id
   where l.code = trim(p_code);
  if not found or q.status = 'rejected' then raise exception 'That question link doesn''t work any more'; end if;
  if q.status <> 'approved' then raise exception 'That question is still waiting for a moderator'; end if;
  if q.created_by is distinct from uid then
    -- Every open is recorded; it only lets you see the question when it was written for friends.
    insert into public.question_link_opens (user_id, question_id) values (uid, q.id) on conflict do nothing;
    first_open := found;
    if first_open and q.created_by is not null then
      insert into public.follows (follower, followed) values (uid, q.created_by) on conflict do nothing;
      requested := found;
    end if;
  end if;
  return json_build_object('id', q.id, 'by_id', q.created_by,
    'by', (select display_name from public.profiles where id = q.created_by),
    'friends', q.created_by = uid or public.are_friends(uid, q.created_by),
    'following', exists (select 1 from public.follows where follower = uid and followed = q.created_by),
    'requested', requested);
end $$;

notify pgrst, 'reload schema';

-- Admin area: review suggested questions, manage the question bank, read
-- feedback and reports, and see who changed what on a question (the audit log).
--
--   * Only accounts listed in public.admins can use it. Every admin_* function
--     checks that on the server, so hiding the button in the app is not what
--     keeps people out. Max's @harley is the first admin.
--   * Add one in the SQL Editor:
--       insert into public.admins (user_id) select id from public.profiles where handle = 'handle';
--     Remove one:
--       delete from public.admins where user_id = (select id from public.profiles where handle = 'handle');
--   * The audit log is written by a trigger on questions, so it also records
--     changes made in the Table Editor or SQL Editor (shown with no person).
--     It covers questions for everyone; friend questions stay between friends
--     unless someone reports one.
--   * Notes an admin leaves on a report or on feedback are part of that row,
--     so the person who sent it sees them in "Download my data".
--
-- Safe to run twice.

create table if not exists public.admins (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;  -- no policies: only is_admin() reads it
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

create or replace function public.require_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'Only admins can do that' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- Who reviewed a question, when, and why.
alter table public.questions add column if not exists reviewed_by uuid references public.profiles (id) on delete set null;
alter table public.questions add column if not exists reviewed_at timestamptz;
alter table public.questions add column if not exists review_note text;

-- Feedback and reports get an inbox status and a note.
alter table public.feedback add column if not exists status text not null default 'open';
do $$ begin
  alter table public.feedback add constraint feedback_status check (status in ('open', 'done'));
exception when duplicate_object then null; end $$;
alter table public.feedback add column if not exists admin_note text;
alter table public.feedback add column if not exists handled_by uuid references public.profiles (id) on delete set null;
alter table public.feedback add column if not exists handled_at timestamptz;
alter table public.reports add column if not exists admin_note text;
alter table public.reports add column if not exists handled_by uuid references public.profiles (id) on delete set null;
alter table public.reports add column if not exists handled_at timestamptz;
create index if not exists feedback_status on public.feedback (status, created_at desc);
create index if not exists reports_status on public.reports (status, created_at desc);

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

create table if not exists public.question_audit (
  id bigint generated always as identity primary key,
  question_id bigint references public.questions (id) on delete cascade,
  actor uuid references public.profiles (id) on delete set null,  -- null = Table Editor / SQL Editor / a timer
  action text not null,                -- submitted, approved, rejected, reopened, edited
  old_value jsonb,
  new_value jsonb,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists question_audit_question on public.question_audit (question_id, created_at desc);
create index if not exists question_audit_time on public.question_audit (created_at desc);
alter table public.question_audit enable row level security;  -- no policies: read through admin_audit()
revoke all on public.question_audit from anon, authenticated;

-- An admin function passes its note to the trigger through this setting.
create or replace function public.question_audit_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  note text := nullif(current_setting('yeahnah.audit_note', true), '');
  old_edit jsonb; new_edit jsonb;
begin
  if tg_op = 'INSERT' then
    if new.created_by is not null and new.audience = 'public' then
      insert into public.question_audit (question_id, actor, action, new_value)
      values (new.id, new.created_by, 'submitted',
              jsonb_build_object('text', new.text, 'category', new.category, 'status', new.status));
    end if;
    return new;
  end if;

  old_edit := jsonb_build_object('text', old.text, 'category', old.category, 'sensitivity', old.sensitivity,
                                 'option_yes', old.option_yes, 'option_no', old.option_no);
  new_edit := jsonb_build_object('text', new.text, 'category', new.category, 'sensitivity', new.sensitivity,
                                 'option_yes', new.option_yes, 'option_no', new.option_no);
  if old_edit is distinct from new_edit then
    -- Only the fields that changed.
    select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, new_edit -> o.key)
      into old_edit, new_edit
      from jsonb_each(old_edit) o where o.value is distinct from new_edit -> o.key;
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(), 'edited', old_edit, new_edit, note);
  end if;
  if old.status is distinct from new.status then
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(),
            case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' else 'reopened' end,
            jsonb_build_object('status', old.status), jsonb_build_object('status', new.status), note);
  end if;
  return new;
end $$;
drop trigger if exists question_audit on public.questions;
create trigger question_audit after insert or update on public.questions
  for each row execute function public.question_audit_trigger();

-- Suggestions sent before this update get their "submitted" line once.
insert into public.question_audit (question_id, actor, action, new_value, created_at)
select q.id, q.created_by, 'submitted',
       jsonb_build_object('text', q.text, 'category', q.category, 'status', q.status), q.created_at
  from public.questions q
 where q.created_by is not null and q.audience = 'public'
   and not exists (select 1 from public.question_audit a where a.question_id = q.id and a.action = 'submitted');

-- ---------------------------------------------------------------------------
-- What the admin screens read
-- ---------------------------------------------------------------------------

-- Counts for the badge on the Admin button.
create or replace function public.admin_summary() returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return json_build_object(
    'pending', (select count(*) from public.questions where status = 'pending'),
    'reports', (select count(*) from public.reports where status = 'open'),
    'feedback', (select count(*) from public.feedback where status = 'open'));
end $$;

-- Questions for everyone, newest first. p_status: pending, approved, rejected or null for all.
-- p_people_only = true leaves out the built-in bank (only questions people wrote).
create or replace function public.admin_questions(p_status text default 'pending', p_search text default null,
  p_people_only boolean default false, p_limit int default 50, p_offset int default 0) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select q.id, q.text, q.category, q.sensitivity, q.option_yes, q.option_no, q.status, q.audience,
           q.is_event, q.daily_date, q.created_at, q.reviewed_at, q.review_note,
           (select handle from public.profiles where id = q.reviewed_by) as reviewed_by,
           case when q.created_by is not null then json_build_object(
             'handle', p.handle, 'name', p.display_name, 'joined', p.created_at,
             'approved', (select count(*) from public.questions o where o.created_by = q.created_by and o.audience = 'public' and o.status = 'approved'),
             'rejected', (select count(*) from public.questions o where o.created_by = q.created_by and o.audience = 'public' and o.status = 'rejected'))
           end as author,
           (select count(*) from public.statements s where s.question_id = q.id and s.superseded_at is null) as answers,
           (select count(*) from public.reports r where r.question_id = q.id and r.status = 'open') as open_reports
      from public.questions q
      left join public.profiles p on p.id = q.created_by
     where q.audience = 'public'
       and (p_status is null or q.status = p_status)
       and (not p_people_only or q.created_by is not null)
       and (p_search is null or trim(p_search) = '' or q.text ilike '%' || trim(p_search) || '%'
            or q.category ilike trim(p_search) or p.handle = lower(trim(both '@ ' from p_search)))
     order by q.created_at desc, q.id desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x);
end $$;

-- Change a question: approve, reject, put back to pending, and/or edit it.
-- Rejecting a suggestion can hand back what it cost (p_refund).
create or replace function public.admin_set_question(p_question bigint, p_status text default null,
  p_text text default null, p_category text default null, p_sensitivity text default null,
  p_note text default null, p_refund boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); q public.questions; paid int;
begin
  select * into q from public.questions where id = p_question for update;
  if not found then raise exception 'No such question'; end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Status is pending, approved or rejected';
  end if;
  if p_text is not null and char_length(trim(p_text)) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  if p_sensitivity is not null and p_sensitivity not in ('standard', 'personal', 'sensitive') then
    raise exception 'Sensitivity is standard, personal or sensitive';
  end if;

  perform set_config('yeahnah.audit_note', coalesce(trim(p_note), ''), true);
  update public.questions set
    text = coalesce(nullif(trim(p_text), ''), text),
    category = coalesce(nullif(trim(p_category), ''), category),
    sensitivity = coalesce(p_sensitivity::public.sensitivity, sensitivity),
    status = coalesce(p_status, status),
    reviewed_by = case when p_status is not null then uid else reviewed_by end,
    reviewed_at = case when p_status is not null then now() else reviewed_at end,
    review_note = case when p_status is not null then nullif(trim(p_note), '') else review_note end
   where id = p_question;
  perform set_config('yeahnah.audit_note', '', true);

  -- Hand back what the suggestion cost, once.
  if p_refund and p_status = 'rejected' and q.created_by is not null
     and not exists (select 1 from public.credit_ledger where question_id = p_question and reason = 'suggest_refund') then
    select coalesce(-sum(amount), 0) into paid from public.credit_ledger
     where question_id = p_question and user_id = q.created_by and reason = 'suggest';
    if paid > 0 then
      insert into public.credit_ledger (user_id, amount, reason, question_id)
      values (q.created_by, paid, 'suggest_refund', p_question);
      insert into public.question_audit (question_id, actor, action, new_value)
      values (p_question, uid, 'refunded', jsonb_build_object('slashes', paid));
    end if;
  end if;
end $$;

-- The audit log, for one question or for everything.
create or replace function public.admin_audit(p_question bigint default null, p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select a.id, a.question_id, a.action, a.old_value, a.new_value, a.note, a.created_at,
           p.handle as actor, q.text as question
      from public.question_audit a
      left join public.profiles p on p.id = a.actor
      left join public.questions q on q.id = a.question_id
     where p_question is null or a.question_id = p_question
     order by a.created_at desc, a.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

-- Reports about questions or people. A reported friend question's text is shown here,
-- so an admin can check it.
create or replace function public.admin_reports(p_status text default 'open', p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select r.id, r.reason, r.status, r.admin_note, r.created_at, r.handled_at,
           (select handle from public.profiles where id = r.handled_by) as handled_by,
           (select handle from public.profiles where id = r.reporter) as reporter,
           (select handle from public.profiles where id = r.target_user) as target,
           case when q.id is not null then json_build_object('id', q.id, 'text', q.text, 'status', q.status,
             'audience', q.audience, 'by', (select handle from public.profiles where id = q.created_by)) end as question,
           (select count(*) from public.reports o where o.question_id = r.question_id and r.question_id is not null) as reports_on_question
      from public.reports r
      left join public.questions q on q.id = r.question_id
     where p_status is null or r.status = p_status
     order by r.created_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

-- Close a report. p_hide_question also takes the reported question down.
create or replace function public.admin_set_report(p_report bigint, p_status text,
  p_note text default null, p_hide_question boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); r public.reports;
begin
  if p_status not in ('open', 'actioned', 'dismissed') then raise exception 'Status is open, actioned or dismissed'; end if;
  update public.reports set status = p_status, admin_note = nullif(trim(p_note), ''),
         handled_by = case when p_status = 'open' then null else uid end,
         handled_at = case when p_status = 'open' then null else now() end
   where id = p_report returning * into r;
  if not found then raise exception 'No such report'; end if;
  if p_hide_question and r.question_id is not null then
    perform public.admin_set_question(r.question_id, 'rejected', p_note => coalesce(nullif(trim(p_note), ''), 'Reported: ' || r.reason));
  end if;
end $$;

create or replace function public.admin_feedback(p_status text default 'open', p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select f.id, f.body, f.context, f.status, f.admin_note, f.created_at, f.handled_at,
           (select handle from public.profiles where id = f.handled_by) as handled_by,
           p.handle, p.display_name as name
      from public.feedback f
      left join public.profiles p on p.id = f.user_id
     where p_status is null or f.status = p_status
     order by f.created_at desc, f.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

create or replace function public.admin_set_feedback(p_feedback bigint, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin();
begin
  if p_status not in ('open', 'done') then raise exception 'Status is open or done'; end if;
  update public.feedback set status = p_status, admin_note = nullif(trim(p_note), ''),
         handled_by = case when p_status = 'done' then uid end,
         handled_at = case when p_status = 'done' then now() end
   where id = p_feedback;
  if not found then raise exception 'No such feedback'; end if;
end $$;

revoke execute on function public.is_admin(), public.require_admin(), public.question_audit_trigger(),
  public.admin_summary(), public.admin_questions(text, text, boolean, int, int),
  public.admin_set_question(bigint, text, text, text, text, text, boolean),
  public.admin_audit(bigint, int), public.admin_reports(text, int),
  public.admin_set_report(bigint, text, text, boolean), public.admin_feedback(text, int),
  public.admin_set_feedback(bigint, text, text)
from public, anon, authenticated;
grant execute on function public.is_admin(),
  public.admin_summary(), public.admin_questions(text, text, boolean, int, int),
  public.admin_set_question(bigint, text, text, text, text, text, boolean),
  public.admin_audit(bigint, int), public.admin_reports(text, int),
  public.admin_set_report(bigint, text, text, boolean), public.admin_feedback(text, int),
  public.admin_set_feedback(bigint, text, text)
to authenticated;

-- Max's own account.
insert into public.admins (user_id) select id from public.profiles where handle = 'harley' on conflict do nothing;

notify pgrst, 'reload schema';

-- The daily question from the admin area, and a daily slot that can't go empty.
--
--   * admin_set_daily(question, date) makes a question the daily question for
--     today or a later day; admin_set_daily(null, date) clears that day so the
--     bank fills it. admin_create_question writes a new question for everyone,
--     live straight away, to use as a daily question or just for the bank.
--   * admin_daily() lists the last few days and the next two weeks, and says
--     whether the hourly timer (pg_cron) that fills empty days is running.
--   * ensure_daily() now skips a dated question that isn't live (taken down
--     or waiting), so taking down today's question gets it replaced. Anyone
--     signed in can call it: the app does when it finds no question for
--     today, so the day fills even if the timer isn't running.
--   * The audit log records daily question changes too.
--
-- Safe to run twice.

-- Fill today and tomorrow from the bank when they have no live question.
create or replace function public.ensure_daily() returns void
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  foreach d in array array[public.today_uk(), public.today_uk() + 1] loop
    if not exists (select 1 from public.questions where daily_date = d and status = 'approved') then
      begin
        update public.questions set daily_date = null where daily_date = d;
        update public.questions set daily_date = d
         where id = (select id from public.questions
                      where status = 'approved' and sensitivity = 'standard' and not is_event
                        and audience = 'public' and daily_date is null
                      order by id limit 1);
      exception when unique_violation then null;  -- someone else filled it at the same moment
      end;
    end if;
  end loop;
end $$;
revoke execute on function public.ensure_daily() from public, anon;
grant execute on function public.ensure_daily() to authenticated;

-- Audit: the same as before, plus changes to daily_date.
create or replace function public.question_audit_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  note text := nullif(current_setting('yeahnah.audit_note', true), '');
  old_edit jsonb; new_edit jsonb;
begin
  if tg_op = 'INSERT' then
    if new.created_by is not null and new.audience = 'public' then
      insert into public.question_audit (question_id, actor, action, new_value)
      values (new.id, new.created_by, 'submitted',
              jsonb_build_object('text', new.text, 'category', new.category, 'status', new.status));
    end if;
    if new.daily_date is not null and new.created_by is not null then
      insert into public.question_audit (question_id, actor, action, new_value, note)
      values (new.id, auth.uid(), 'daily', jsonb_build_object('daily_date', new.daily_date), note);
    end if;
    return new;
  end if;

  old_edit := jsonb_build_object('text', old.text, 'category', old.category, 'sensitivity', old.sensitivity,
                                 'option_yes', old.option_yes, 'option_no', old.option_no);
  new_edit := jsonb_build_object('text', new.text, 'category', new.category, 'sensitivity', new.sensitivity,
                                 'option_yes', new.option_yes, 'option_no', new.option_no);
  if old_edit is distinct from new_edit then
    -- Only the fields that changed.
    select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, new_edit -> o.key)
      into old_edit, new_edit
      from jsonb_each(old_edit) o where o.value is distinct from new_edit -> o.key;
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(), 'edited', old_edit, new_edit, note);
  end if;
  if old.status is distinct from new.status then
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(),
            case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' else 'reopened' end,
            jsonb_build_object('status', old.status), jsonb_build_object('status', new.status), note);
  end if;
  if old.daily_date is distinct from new.daily_date then
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(), 'daily',
            jsonb_build_object('daily_date', old.daily_date), jsonb_build_object('daily_date', new.daily_date), note);
  end if;
  return new;
end $$;

-- Make a question the daily question on a day (today or later), or clear the day.
create or replace function public.admin_set_daily(p_question bigint, p_date date, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); q public.questions;
begin
  if p_date is null or p_date < public.today_uk() then raise exception 'Pick today or a later day'; end if;
  perform pg_advisory_xact_lock(hashtextextended('daily', 0));
  perform set_config('yeahnah.audit_note', coalesce(trim(p_note), ''), true);
  if p_question is not null then
    select * into q from public.questions where id = p_question for update;
    if not found then raise exception 'No such question'; end if;
    if q.status <> 'approved' or q.audience <> 'public' or q.is_event then
      raise exception 'The daily question has to be a live question for everyone';
    end if;
    if q.daily_date = p_date then return; end if;
    if q.daily_date is not null and q.daily_date < public.today_uk() then
      raise exception 'That was already the daily question on %', to_char(q.daily_date, 'DD Mon');
    end if;
  end if;
  update public.questions set daily_date = null where daily_date = p_date;
  if p_question is not null then
    update public.questions set daily_date = p_date where id = p_question;
  end if;
  perform set_config('yeahnah.audit_note', '', true);
  -- An emptied today or tomorrow is filled from the bank straight away.
  perform public.ensure_daily();
end $$;

-- A new question for everyone, written by an admin: live straight away.
create or replace function public.admin_create_question(p_text text, p_category text default 'General',
  p_sensitivity text default 'standard', p_option_yes text default null, p_option_no text default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); new_id bigint;
begin
  if char_length(trim(coalesce(p_text, ''))) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  if (nullif(trim(p_option_yes), '') is null) <> (nullif(trim(p_option_no), '') is null) then
    raise exception 'A pick needs both options';
  end if;
  if coalesce(p_sensitivity, 'standard') not in ('standard', 'personal', 'sensitive') then
    raise exception 'Sensitivity is standard, personal or sensitive';
  end if;
  insert into public.questions (text, category, sensitivity, option_yes, option_no, status, audience, created_by,
                                reviewed_by, reviewed_at, review_note)
  values (trim(p_text), coalesce(nullif(trim(p_category), ''), 'General'), coalesce(p_sensitivity, 'standard')::public.sensitivity,
          nullif(trim(p_option_yes), ''), nullif(trim(p_option_no), ''), 'approved', 'public', uid,
          uid, now(), 'Written by an admin')
  returning id into new_id;
  return new_id;
end $$;

-- The daily schedule: the last 3 days, today and the next p_days, plus whether the timer runs.
create or replace function public.admin_daily(p_days int default 14) returns json
language plpgsql stable security definer set search_path = '' as $$
declare timer boolean := false;
begin
  perform public.require_admin();
  if to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = ''ensure-daily'' and active)' into timer;
  end if;
  return json_build_object(
    'today', public.today_uk(),
    'timer', timer,
    'bank_left', (select count(*) from public.questions
                   where status = 'approved' and sensitivity = 'standard' and not is_event
                     and audience = 'public' and daily_date is null),
    'days', (select json_agg(json_build_object(
               'date', d::date,
               'question', (select json_build_object('id', q.id, 'text', q.text, 'category', q.category, 'status', q.status,
                                  'answers', (select count(*) from public.statements s where s.question_id = q.id and s.superseded_at is null))
                              from public.questions q where q.daily_date = d::date))
             order by d)
             from generate_series(public.today_uk() - 3, public.today_uk() + least(greatest(p_days, 1), 60), interval '1 day') d));
end $$;

revoke execute on function public.admin_set_daily(bigint, date, text),
  public.admin_create_question(text, text, text, text, text), public.admin_daily(int)
from public, anon, authenticated;
grant execute on function public.admin_set_daily(bigint, date, text),
  public.admin_create_question(text, text, text, text, text), public.admin_daily(int)
to authenticated;

-- Schedule the hourly timer again, in case it was skipped when the database
-- was set up (pg_cron is on every Supabase project, but may need switching
-- on under Database > Extensions). Re-scheduling the same name just updates it.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('ensure-daily', '0 * * * *', 'select public.ensure_daily()');
  perform cron.schedule('resolve-predictions', '5 * * * *', 'select public.resolve_due()');
exception when others then
  raise notice 'pg_cron not available (%): the app fills empty days itself', sqlerrm;
end $$;

-- Fill today now.
select public.ensure_daily();

notify pgrst, 'reload schema';

-- Share any everyday question as a link, from the Send panel, not just ones
-- you wrote. Each person gets their own link to a question, so whoever opens
-- it sees who shared it and sends the sharer the friend request. Questions
-- written for friends can still only be shared by the person who wrote them,
-- and sensitive questions and events can't be shared.
--
-- Safe to run twice.

alter table public.question_links add column if not exists shared_by uuid references public.profiles (id) on delete cascade;
update public.question_links l set shared_by = q.created_by
  from public.questions q where q.id = l.question_id and l.shared_by is null;

-- One link per question per sharer (it was one per question).
do $$ begin
  if exists (select 1 from pg_constraint c join pg_attribute a on a.attrelid = c.conrelid and a.attnum = any (c.conkey)
              where c.conrelid = 'public.question_links'::regclass and c.contype = 'p' and a.attname = 'question_id') then
    alter table public.question_links drop constraint question_links_pkey;
    alter table public.question_links add primary key (code);
  end if;
end $$;
create unique index if not exists question_links_sharer on public.question_links (question_id, shared_by);

create or replace function public.share_question(p_question bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions; c text;
begin
  select * into q from public.questions where id = p_question;
  if not found or q.status = 'rejected' then raise exception 'Question not found'; end if;
  if q.created_by is distinct from uid then
    if q.audience = 'friends' then
      raise exception 'Only the person who wrote a friends question can share it as a link';
    end if;
    if q.status <> 'approved' or q.is_event or q.sensitivity = 'sensitive' or not public.can_see_question(uid, q) then
      raise exception 'That question can''t be shared as a link';
    end if;
  end if;
  insert into public.question_links (question_id, shared_by) values (p_question, uid)
  on conflict (question_id, shared_by) do nothing;
  select code into c from public.question_links where question_id = p_question and shared_by = uid;
  return c;
end $$;

-- The sign-up page names whoever shared the link.
create or replace function public.question_preview(p_code text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object('text', q.text, 'by', p.display_name, 'live', q.status = 'approved')
    from public.question_links l
    join public.questions q on q.id = l.question_id and q.status <> 'rejected'
    left join public.profiles p on p.id = coalesce(l.shared_by, q.created_by)
   where l.code = trim(p_code)
$$;

-- Opening a link: as before (20261024), but the friend request goes to whoever shared it.
create or replace function public.open_question_link(p_code text) returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions; qid bigint; sharer uuid;
        first_open boolean := false; requested boolean := false;
begin
  select l.question_id, l.shared_by into qid, sharer from public.question_links l where l.code = trim(p_code);
  select * into q from public.questions where id = qid;
  if not found or q.status = 'rejected' then raise exception 'That question link doesn''t work any more'; end if;
  if q.status <> 'approved' then raise exception 'That question is still waiting for a moderator'; end if;
  sharer := coalesce(sharer, q.created_by);
  if q.created_by is distinct from uid then
    -- Every open is recorded; it only lets you see the question when it was written for friends.
    insert into public.question_link_opens (user_id, question_id) values (uid, q.id) on conflict do nothing;
    first_open := found;
  end if;
  if first_open and sharer is not null and sharer <> uid then
    insert into public.follows (follower, followed) values (uid, sharer) on conflict do nothing;
    requested := found;
  end if;
  return json_build_object('id', q.id, 'by_id', sharer,
    'by', (select display_name from public.profiles where id = sharer),
    'friends', sharer = uid or public.are_friends(uid, sharer),
    'following', exists (select 1 from public.follows where follower = uid and followed = sharer),
    'requested', requested);
end $$;

notify pgrst, 'reload schema';

-- Hot ones: the everyday questions people have starred and answered most over
-- the last few days. They're a theme of their own in the Questions tab, and
-- they're dealt into the Today hand after your own starred questions and
-- before the rest.
--
-- Only the list of questions comes back, never counts or who did what, and a
-- question needs stars or answers from at least hot_min_people different
-- people before it can be hot, so a small group can't work out who starred
-- what. Answers given on the day a question was the daily question don't
-- count (everyone answers that one), and nor do questions written for friends.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('hot_days', 7),           -- stars and answers from this many days count
  ('hot_count', 12),         -- how many questions are hot at once
  ('hot_star_weight', 3),    -- a star counts as this many answers
  ('hot_min_people', 3)      -- different people a question needs before it can be hot
on conflict (key) do nothing;

-- Hot question ids for whoever is signed in, hottest first. Questions they
-- can't see (sensitive ones without the opt-in, future dailies) are left out.
create or replace function public.hot_questions() returns setof bigint
language sql stable security definer set search_path = '' as $$
  with since as (select now() - make_interval(days => public.cfg('hot_days')) as t),
  activity as (
    select s.question_id, s.user_id, public.cfg('hot_star_weight') as points
      from public.stars s, since where s.created_at >= since.t
    union all
    select st.question_id, st.user_id, 1
      from public.statements st join public.questions q on q.id = st.question_id, since
     where st.created_at >= since.t and st.replaces is null
       and q.daily_date is distinct from (st.created_at at time zone 'Europe/London')::date
  ),
  scored as (
    select question_id, sum(points) as score, count(distinct user_id) as people
      from activity group by question_id
  )
  select q.id
    from scored sc join public.questions q on q.id = sc.question_id
   where q.audience = 'public' and not q.is_event and q.status = 'approved'
     and sc.people >= public.cfg('hot_min_people')
     and public.can_see_question(auth.uid(), q)
   order by sc.score desc, sc.people desc, q.id
   limit public.cfg('hot_count')
$$;
revoke execute on function public.hot_questions() from public, anon;
grant execute on function public.hot_questions() to authenticated;

notify pgrst, 'reload schema';

-- Answer before signing up: someone who opens a question link without an
-- account gets a hand of guest_answers (5) questions, the linked one first,
-- and sees how everyone answered each one. The answers stay on their phone
-- until they sign up, then claim_guest_answers saves them to the new profile.
--
-- Saved guest answers have source 'link', so they don't use up the day's
-- answers: a new account still gets its 5 that day. Today's question is only
-- in the guest hand when it's the one that was linked, so it's still there to
-- answer after signing up unless it was already answered from the link.
--
-- Answers can only be claimed once per account, by an account made in the
-- last day, so the daily limit can't be dodged by claiming again.
--
-- Safe to run twice.

insert into public.app_config (key, value) values ('guest_answers', 5) on conflict (key) do nothing;

alter table public.profiles add column if not exists guest_claimed_at timestamptz;

-- Questions a guest can answer from a link: everyday ones that anyone can see,
-- nothing sensitive, and not today's or a future daily question.
create or replace function public.guest_can_answer(q public.questions, p_linked bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select q.status = 'approved' and not q.is_event and q.sensitivity <> 'sensitive'
     and (q.daily_date is null or q.daily_date <= public.today_uk())
     and case when q.id = p_linked then true
              else q.audience = 'public' and q.daily_date is distinct from public.today_uk() end
$$;
revoke execute on function public.guest_can_answer(public.questions, bigint) from public, anon, authenticated;

-- The guest hand for a link: the linked question first, then the rest picked
-- at random. Needs a working link, so the whole bank can't be read without one.
create or replace function public.guest_hand(p_code text) returns json
language sql stable security definer set search_path = '' as $$
  with link as (
    select l.question_id as id, p.display_name as sharer
      from public.question_links l
      join public.questions q on q.id = l.question_id
      left join public.profiles p on p.id = coalesce(l.shared_by, q.created_by)
     where l.code = trim(p_code)
  ),
  picked as (
    select q.*, 0 as ord from public.questions q, link where q.id = link.id and public.guest_can_answer(q, link.id)
    union all
    (select q.*, 1 from public.questions q, link
      where q.id <> link.id and public.guest_can_answer(q, link.id)
        and exists (select 1 from public.questions lq where lq.id = link.id and public.guest_can_answer(lq, link.id))
      order by random() limit public.cfg('guest_answers') - 1)
  )
  select coalesce(json_agg(json_build_object(
           'id', id, 'text', text, 'category', category, 'sensitivity', sensitivity,
           'option_yes', option_yes, 'option_no', option_no, 'emoji_yes', emoji_yes, 'emoji_no', emoji_no,
           'linked', ord = 0, 'by', case when ord = 0 then (select sharer from link) end)
         order by ord), '[]')
    from picked
$$;
revoke execute on function public.guest_hand(text) from public;
grant execute on function public.guest_hand(text) to anon, authenticated;

-- How everyone answered one of the questions in a link's guest hand.
create or replace function public.guest_split(p_code text, p_question bigint) returns json
language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.question_links l join public.questions q on q.id = p_question
                             where l.code = trim(p_code) and public.guest_can_answer(q, l.question_id))
    then (select json_build_object(
            'yes', count(*) filter (where value),
            'no', count(*) filter (where not value),
            'total', count(*))
          from public.statements where question_id = p_question and superseded_at is null)
    end
$$;
revoke execute on function public.guest_split(text, bigint) from public;
grant execute on function public.guest_split(text, bigint) to anon, authenticated;

-- Saves the answers given before signing up: [{"question_id": 1, "value": true}, ...].
-- Run it after open_question_link, so a friends-only question from the link is
-- visible. Questions the account can't see or has already answered are
-- skipped. Returns how many were saved.
create or replace function public.claim_guest_answers(p_answers jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.require_profile();
  me public.profiles;
  a jsonb;
  q public.questions;
  vis public.visibility;
  saved int := 0;
begin
  select * into me from public.profiles where id = uid for update;
  if me.guest_claimed_at is not null or me.created_at < now() - interval '1 day' then return 0; end if;
  update public.profiles set guest_claimed_at = now() where id = uid;
  if jsonb_typeof(p_answers) <> 'array' then return 0; end if;

  for a in select value from jsonb_array_elements(p_answers) limit public.cfg('guest_answers') loop
    select * into q from public.questions where id = (a->>'question_id')::bigint;
    continue when not found or jsonb_typeof(a->'value') <> 'boolean'
      or q.status <> 'approved' or q.is_event or q.sensitivity = 'sensitive'
      or (q.daily_date is not null and q.daily_date > public.today_uk())
      or not public.can_see_question(uid, q)
      or exists (select 1 from public.statements where user_id = uid and question_id = q.id and superseded_at is null);
    vis := case when q.audience = 'public' and q.sensitivity = 'standard' and public.cfg('new_answers_public') = 1
                     and public.is_adult(uid)
                then 'public'::public.visibility else 'friends'::public.visibility end;
    insert into public.statements (user_id, question_id, value, visibility, source)
    values (uid, q.id, (a->>'value')::boolean, vis, 'link');
    saved := saved + 1;
  end loop;
  return saved;
end $$;
revoke execute on function public.claim_guest_answers(jsonb) from public, anon;
grant execute on function public.claim_guest_answers(jsonb) to authenticated;

notify pgrst, 'reload schema';
