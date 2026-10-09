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
