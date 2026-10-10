-- Answer stats: tap the yeah/nah bar on a card you've answered for a closer
-- look at who said what.
--
-- Everything comes back as counts, and each count follows the same rules as
-- the names people can already see:
--   * Everyone: every current answer, the same numbers as the bar.
--   * Your friends and each of your groups: answers they've let friends see
--     (public or friends, not hidden after a change of mind), plus your own
--     in your groups, as on the Group tab.
--   * Age groups: public answers only. An age group with fewer than
--     stats_min_people answers isn't shown, so nobody can be picked out.
--   * Over time: the split as it stood at the end of each day. A day only
--     gets its own point once at least stats_min_people more people have
--     answered since the last point.
--   * Crowd guesses (Future): on a daily question, how many guessed yeah or
--     nah would win, once at least stats_min_people have guessed.
-- You only get stats once you've answered, the same as the bar.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('stats_min_people', 3)    -- fewest answers an age group, day or guess count needs before it shows
on conflict (key) do nothing;

create or replace function public.question_stats(p_question bigint) returns json
language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := auth.uid(); n int := public.cfg('stats_min_people'); result json;
  d record; points json[] := '{}'; last_total bigint := 0;
begin
  if uid is null or not exists (
      select 1 from public.statements
       where user_id = uid and question_id = p_question and superseded_at is null) then
    return null;
  end if;

  -- The split at the end of each day, keeping a day only once n more people
  -- have answered since the last day kept.
  for d in
    select day, sum(yes) over w as yes, sum(total) over w as total
      from (select (created_at at time zone 'Europe/London')::date as day,
                   count(*) filter (where value) as yes, count(*) as total
              from public.statements
             where question_id = p_question and superseded_at is null
             group by 1) x
    window w as (order by day) order by day
  loop
    if d.total - last_total >= n then
      points := points || json_build_object('day', d.day, 'yes', d.yes, 'total', d.total);
      last_total := d.total;
    end if;
  end loop;

  with live as (
    select s.user_id, s.value, s.visibility,
           s.visibility in ('public', 'friends') and (s.hidden_until is null or s.hidden_until < now()) as shared
      from public.statements s
     where s.question_id = p_question and s.superseded_at is null
  ),
  ages as (
    select case when a < 25 then '18–24' when a < 35 then '25–34'
                when a < 45 then '35–44' when a < 55 then '45–54' else '55+' end as band,
           min(a) as lo, count(*) filter (where value) as yes, count(*) as total
      from (select l.value, extract(year from age(p.birth_date))::int as a
              from live l join public.profiles p on p.id = l.user_id
             where l.visibility = 'public' and l.shared) x
     group by 1
  ),
  guesses as (
    select count(*) filter (where pr.predicts_yes) as yes, count(*) as total
      from public.predictions pr
     where pr.question_id = p_question and pr.kind = 'crowd'
  )
  select json_build_object(
    'everyone', (select json_build_object('yes', count(*) filter (where value), 'total', count(*)) from live),
    'friends', (select json_build_object('yes', count(*) filter (where value), 'total', count(*))
                  from live where shared and public.are_friends(uid, user_id)),
    'groups', (select coalesce(json_agg(g order by g.total desc, g.name), '[]') from (
                 select gr.name, count(l.*) filter (where l.value) as yes, count(l.*) as total
                   from public.group_members me
                   join public.groups gr on gr.id = me.group_id
                   join public.group_members gm on gm.group_id = me.group_id
                   join live l on l.user_id = gm.user_id and (l.user_id = uid or l.shared)
                  where me.user_id = uid
                  group by gr.id, gr.name) g),
    'ages', (select coalesce(json_agg(json_build_object('band', band, 'yes', yes, 'total', total) order by lo), '[]')
               from ages where total >= n),
    'days', array_to_json(points),
    'guesses', (select case when total >= n then json_build_object('yes', yes, 'total', total) end from guesses),
    'min_people', n
  ) into result;
  return result;
end $$;

revoke execute on function public.question_stats(bigint) from public, anon;
grant execute on function public.question_stats(bigint) to authenticated;

notify pgrst, 'reload schema';
