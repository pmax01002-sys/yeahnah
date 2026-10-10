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
