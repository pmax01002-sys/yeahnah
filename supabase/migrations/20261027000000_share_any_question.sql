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
