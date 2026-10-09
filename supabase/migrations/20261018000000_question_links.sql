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
