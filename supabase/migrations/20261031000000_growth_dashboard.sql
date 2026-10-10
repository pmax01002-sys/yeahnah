-- Growth: the Admin area's virality dashboard. Totals and trends only: it
-- returns counts and percentages per day or per week, never who did what, so
-- nothing on it points at one person.
--
-- Virality (v) is worked out the same way as the nightly economy record that
-- slashtax will use, with the same app_config numbers, so the two agree:
--   spread  answered sends per weekly active person over 7 days
--   growth  people who came in through a group or question link, per weekly
--           active person over 7 days
--   v       virality_spread_weight% of spread / virality_spread_target
--           + the rest of growth / virality_growth_target, so 1.0 = target pace
--   Weekly active = an account at least a day old with 3 or more answers that
--   answered something in the 7 days. With fewer than virality_min_people of
--   them, v is the manual one (virality_manual) and the dashboard says so.
-- Accounts with unlimited slashes are left out of every number, like the
-- economy record, so the owner's testing doesn't skew them.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('slashtax_allowance', 20),
  ('virality_spread_target', 100),   -- answered sends per active person a week = 1.0
  ('virality_growth_target', 10),    -- link joins per active person a week = 0.10
  ('virality_spread_weight', 70),    -- spread's share of v, in %
  ('virality_min_people', 10),       -- fewer weekly active people than this: use the manual v
  ('virality_manual', 100)           -- that v (1.00)
on conflict (key) do nothing;

-- Virality for the 7 UK days ending with p_day (today counts up to now).
create or replace function public.virality_on(p_day date) returns json
language plpgsql stable security definer set search_path = '' as $$
declare
  d1 timestamptz := least(now(), (p_day + 1)::timestamp at time zone 'Europe/London');
  w0 timestamptz := (p_day - 6)::timestamp at time zone 'Europe/London';
  active int; sends7 int; joins7 int; s numeric; g numeric; vv numeric; manual boolean;
begin
  select count(*) into active from public.profiles p
   where p.created_at < d1 - interval '1 day'
     and not public.has_unlimited_slashes(p.id)
     and (select count(*) from public.statements s where s.user_id = p.id and s.created_at < d1) >= 3
     and exists (select 1 from public.statements s where s.user_id = p.id and s.created_at >= w0 and s.created_at < d1);

  select count(*) into sends7 from public.challenges
   where answered_at >= w0 and answered_at < d1 and answered_at <= expires_at;

  select count(*) into joins7 from public.profiles p
   where p.created_at >= w0 and p.created_at < d1
     and not public.has_unlimited_slashes(p.id)
     and (exists (select 1 from public.group_members m where m.user_id = p.id
                   and m.joined_at < p.created_at + interval '1 hour')
          or exists (select 1 from public.question_link_opens o where o.user_id = p.id
                      and o.opened_at < p.created_at + interval '1 hour'));

  manual := active < public.cfg('virality_min_people');
  s := case when active > 0 then sends7::numeric / active else 0 end;
  g := case when active > 0 then joins7::numeric / active else 0 end;
  vv := public.cfg('virality_spread_weight') / 100.0 * s / (public.cfg('virality_spread_target') / 100.0)
      + (1 - public.cfg('virality_spread_weight') / 100.0) * g / (public.cfg('virality_growth_target') / 100.0);
  return json_build_object(
    'weekly_active', active, 'answered_sends', sends7, 'link_joins', joins7,
    'spread', round(s, 3), 'growth', round(g, 3),
    'v_measured', round(vv, 2),
    'v', case when manual then round(public.cfg('virality_manual') / 100.0, 2) else round(vv, 2) end,
    'v_is_manual', manual, 'min_people', public.cfg('virality_min_people'),
    'spread_target', public.cfg('virality_spread_target') / 100.0,
    'spread_weight', public.cfg('virality_spread_weight') / 100.0,
    'growth_target', public.cfg('virality_growth_target') / 100.0);
end $$;
revoke execute on function public.virality_on(date) from public, anon, authenticated;

-- Everything the Growth screen shows, for the last p_days UK days (7 to 90).
create or replace function public.admin_growth(p_days int default 28) returns json
language plpgsql stable security definer set search_path = '' as $$
declare
  span int := greatest(7, least(coalesce(p_days, 28), 90));
  this_day date := public.today_uk();
  from_day date := this_day - span + 1;
  since timestamptz := (this_day - span + 1)::timestamp at time zone 'Europe/London';
  week_start timestamptz := (this_day - 6)::timestamp at time zone 'Europe/London';
  prev_start timestamptz := (this_day - 13)::timestamp at time zone 'Europe/London';
  result json;
begin
  perform public.require_admin();

  with people as (
    select p.id, p.created_at, (p.created_at at time zone 'Europe/London')::date as joined,
           exists (select 1 from public.group_members m where m.user_id = p.id
                    and m.joined_at < p.created_at + interval '1 hour') as via_group,
           exists (select 1 from public.question_link_opens o where o.user_id = p.id
                    and o.opened_at < p.created_at + interval '1 hour') as via_link
      from public.profiles p
     where not exists (select 1 from public.unlimited_slashes u where u.user_id = p.id)
  ),
  answers as (  -- first answers only; a change of mind isn't a new answer
    select s.user_id, s.question_id, s.visibility, s.via_challenge, s.created_at,
           (s.created_at at time zone 'Europe/London')::date as day
      from public.statements s join people p on p.id = s.user_id
     where s.replaces is null
  ),
  sends as (
    select c.*, (c.created_at at time zone 'Europe/London')::date as day,
           (c.answered_at at time zone 'Europe/London')::date as answered_day
      from public.challenges c join people p on p.id = c.from_user
  ),
  days as (select g::date as day from generate_series(from_day, this_day, interval '1 day') g),
  daily as (
    select d.day,
      (select count(*) from people p where p.joined = d.day) as signups,
      (select count(*) from people p where p.joined = d.day and (p.via_group or p.via_link)) as link_signups,
      (select count(distinct a.user_id) from answers a where a.day = d.day) as answerers,
      (select count(*) from answers a where a.day = d.day) as answers,
      (select count(*) from answers a join public.questions q on q.id = a.question_id
        where a.day = d.day and q.daily_date = d.day) as daily_answers,
      (select count(*) from sends c where c.day = d.day) as sends,
      (select count(*) from sends c where c.answered_day = d.day and c.answered_at <= c.expires_at) as sends_answered,
      (select count(*) from public.question_link_opens o join people p on p.id = o.user_id
        where (o.opened_at at time zone 'Europe/London')::date = d.day) as link_opens,
      (select count(*) from public.stars s join people p on p.id = s.user_id
        where (s.created_at at time zone 'Europe/London')::date = d.day) as stars
    from days d
  ),
  friends as (  -- mutual follows, per person
    select p.id, (select count(*) from public.follows f
                   where f.follower = p.id
                     and exists (select 1 from public.follows b where b.follower = f.followed and b.followed = p.id)) as n
      from people p
  ),
  -- Weekly cohorts by the Monday of the week people joined, last 8 weeks.
  cohorts as (
    select date_trunc('week', p.joined)::date as cohort, p.id, p.joined from people p
     where p.joined >= date_trunc('week', this_day)::date - 49
  ),
  cohort_cells as (  -- % of each cohort who answered something in its week 0 (the week they joined) to week 4
    select c.cohort, w, count(distinct c.id) as size,
           case when c.cohort + 7 * w <= this_day then
             round(100.0 * count(distinct a.user_id) filter (where a.day >= c.cohort + 7 * w and a.day < c.cohort + 7 * (w + 1))
                   / count(distinct c.id)) end as pct
      from cohorts c cross join generate_series(0, 4) w
      left join answers a on a.user_id = c.id
     group by c.cohort, w
  ),
  cohort_weeks as (
    select cohort, max(size) as size, array_agg(pct order by w) as active_pct from cohort_cells group by cohort
  )
  select json_build_object(
    'days', span,
    'today', this_day,
    'virality', public.virality_on(this_day),
    'virality_trend', (select json_agg(json_build_object('day', d.day, 'v', (public.virality_on(d.day) ->> 'v_measured')::numeric) order by d.day)
                         from days d),
    'people', (select count(*) from people),
    'active', json_build_object(
      'today', (select count(distinct user_id) from answers where day = this_day),
      'week', (select count(distinct user_id) from answers where created_at >= week_start),
      'month', (select count(distinct user_id) from answers where created_at >= this_day::timestamp at time zone 'Europe/London' - interval '27 days')),
    'week', json_build_object(  -- this 7 days and the 7 before, for the arrows
      'signups', json_build_array((select count(*) from people where created_at >= week_start),
                                  (select count(*) from people where created_at >= prev_start and created_at < week_start)),
      'answers', json_build_array((select count(*) from answers where created_at >= week_start),
                                  (select count(*) from answers where created_at >= prev_start and created_at < week_start)),
      'sends', json_build_array((select count(*) from sends where created_at >= week_start),
                                (select count(*) from sends where created_at >= prev_start and created_at < week_start)),
      'link_opens', json_build_array(
        (select count(*) from public.question_link_opens o join people p on p.id = o.user_id where o.opened_at >= week_start),
        (select count(*) from public.question_link_opens o join people p on p.id = o.user_id where o.opened_at >= prev_start and o.opened_at < week_start))),
    -- Of the sends whose timer ran out (or were answered) in the range, how many were answered in time.
    'send_answer_rate', (select round(100.0 * count(*) filter (where answered_at is not null and answered_at <= expires_at)
                                      / nullif(count(*), 0))
                           from sends where least(coalesce(answered_at, expires_at), expires_at) >= since
                                        and least(coalesce(answered_at, expires_at), expires_at) <= now()),
    'came_from', json_build_object(
      'group', (select count(*) from people where created_at >= since and via_group),
      'link', (select count(*) from people where created_at >= since and via_link and not via_group),
      'direct', (select count(*) from people where created_at >= since and not via_group and not via_link)),
    'friends', json_build_object(
      'avg', (select round(avg(n), 1) from friends),
      'with_any', (select round(100.0 * count(*) filter (where n > 0) / nullif(count(*), 0)) from friends),
      'in_groups', (select round(100.0 * count(*) filter (where exists (select 1 from public.group_members m where m.user_id = people.id))
                                 / nullif(count(*), 0)) from people)),
    'visibility', (select json_build_object(
        'public', round(100.0 * count(*) filter (where visibility = 'public') / nullif(count(*), 0)),
        'friends', round(100.0 * count(*) filter (where visibility = 'friends') / nullif(count(*), 0)),
        'private', round(100.0 * count(*) filter (where visibility = 'private') / nullif(count(*), 0)))
      from answers where created_at >= since),
    'retention', json_build_object(
      -- Came back the day after joining, of people who joined in the range before today.
      'day1', (select round(100.0 * count(*) filter (where exists (select 1 from answers a where a.user_id = p.id and a.day = p.joined + 1))
                            / nullif(count(*), 0))
                 from people p where p.joined >= from_day and p.joined < this_day),
      -- Answered something 7 to 13 days after joining, of people who joined at least 13 days ago.
      'week1', (select round(100.0 * count(*) filter (where exists (select 1 from answers a where a.user_id = p.id
                                                                    and a.day between p.joined + 7 and p.joined + 13))
                             / nullif(count(*), 0))
                  from people p where p.joined >= from_day - 13 and p.joined <= this_day - 13)),
    'cohorts', (select coalesce(json_agg(json_build_object('week', cohort, 'size', size, 'active', active_pct) order by cohort desc), '[]')
                  from cohort_weeks),
    'daily', (select json_agg(row_to_json(daily) order by day) from daily),
    'slashes', json_build_object(
      'minted', (select coalesce(sum(amount), 0) from public.credit_ledger c join people p on p.id = c.user_id
                  where amount > 0 and c.created_at >= week_start),
      'spent', (select coalesce(-sum(amount), 0) from public.credit_ledger c join people p on p.id = c.user_id
                 where amount < 0 and c.created_at >= week_start))
  ) into result;
  return result;
end $$;

notify pgrst, 'reload schema';
