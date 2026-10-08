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
