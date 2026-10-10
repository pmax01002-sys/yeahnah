-- A question written for friends is seen only by the friends it was sent to,
-- not by every friend of the person who wrote it. Who can see one now:
--   * the person who wrote it,
--   * anyone it was sent to, by the writer or passed on by someone it was sent to,
--   * anyone who opened its link (only the writer can share that),
--   * anyone who has already answered it, so answers given before this change
--     keep their question.
-- A friend question made without sending it to anyone stays with the writer
-- until they send it or share its link.
--
-- Safe to run twice.

create or replace function public.can_see_question(p_user uuid, q public.questions) returns boolean
language sql stable security definer set search_path = '' as $$
  select case
    when q.created_by = p_user then true
    when q.audience = 'friends' then
      q.status = 'approved' and (
        exists (select 1 from public.challenges where to_user = p_user and question_id = q.id)
        or exists (select 1 from public.question_link_opens where user_id = p_user and question_id = q.id)
        or exists (select 1 from public.statements where user_id = p_user and question_id = q.id))
    else q.status = 'approved' and (q.daily_date is null or q.daily_date <= public.today_uk())
      and (q.sensitivity <> 'sensitive' or public.is_adult(p_user))
  end
$$;

notify pgrst, 'reload schema';
