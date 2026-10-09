-- Avatars: each person can pick one of the pixel avatars (Cap, Specs,
-- Pigtails, Owl, Frog, Fox, each in Red or Blue). Stored as '<sprite>-<palette>',
-- e.g. 'cap-red', matching the app's image names. Null = not picked yet.
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
