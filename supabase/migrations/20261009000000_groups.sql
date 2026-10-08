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
