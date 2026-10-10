-- Question packs: a set of questions dealt into Today together, like a pack of
-- cards, with a cover card in front.
--
--   * The first packs are star-sign starter packs. Everyone gets the one for
--     their sign, worked out from their date of birth here in the database,
--     so the date itself still never reaches the app. October birthdays are
--     Libra up to the 22nd and Scorpio from the 23rd.
--   * todays_pack() deals the next pack once the last one is finished, at most
--     one new pack a day. An unfinished pack stays in Today until it's done,
--     and a pack finished today stays in today's hand.
--   * Pack answers don't use up the daily five. They're marked via_pack, the
--     way answers to friends' questions are marked via_challenge.
--   * Pack questions are only ever dealt as part of their pack: never one by
--     one, never as the daily question, never as Hot ones and never in a
--     guest hand (unless it's the linked question).
--   * Finishing a pack earns its badge. Badges are only shown to their owner
--     for now, because a star-sign badge gives away roughly when your
--     birthday is.
--
-- Safe to run twice.

-- Star sign for a date, by the usual western date ranges.
create or replace function public.star_sign(p_date date) returns text
language sql immutable set search_path = '' as $$
  select case
    when md is null then null
    when md between 321 and 419 then 'aries'
    when md between 420 and 520 then 'taurus'
    when md between 521 and 620 then 'gemini'
    when md between 621 and 722 then 'cancer'
    when md between 723 and 822 then 'leo'
    when md between 823 and 922 then 'virgo'
    when md between 923 and 1022 then 'libra'
    when md between 1023 and 1121 then 'scorpio'
    when md between 1122 and 1221 then 'sagittarius'
    when md >= 1222 or md <= 119 then 'capricorn'
    when md between 120 and 218 then 'aquarius'
    else 'pisces'
  end
  from (select extract(month from p_date)::int * 100 + extract(day from p_date)::int as md) d
$$;

create table if not exists public.badges (
  slug text primary key,
  name text not null,
  blurb text not null
);

create table if not exists public.packs (
  id bigint generated always as identity primary key,
  slug text not null unique,
  name text not null,
  blurb text not null,
  star_sign text check (star_sign in ('aries', 'taurus', 'gemini', 'cancer', 'leo', 'virgo', 'libra',
                                      'scorpio', 'sagittarius', 'capricorn', 'aquarius', 'pisces')),  -- null: for everyone
  badge text references public.badges (slug),   -- earned by finishing the pack
  position int not null default 0,              -- lower is dealt first
  active boolean not null default true,         -- false: no longer dealt
  created_at timestamptz not null default now()
);

create table if not exists public.pack_questions (
  pack_id bigint not null references public.packs (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  position int not null,
  typical boolean,                              -- the answer the pack expects, for the result at the end
  primary key (pack_id, question_id)
);
create index if not exists pack_questions_question on public.pack_questions (question_id);

-- One row per pack dealt to someone. The pack stays in Today until finished.
create table if not exists public.pack_deals (
  user_id uuid not null references public.profiles (id) on delete cascade,
  pack_id bigint not null references public.packs (id) on delete cascade,
  dealt_on date not null default public.today_uk(),
  finished_at timestamptz,
  primary key (user_id, pack_id)
);

create table if not exists public.user_badges (
  user_id uuid not null references public.profiles (id) on delete cascade,
  badge text not null references public.badges (slug) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, badge)
);

alter table public.badges enable row level security;
alter table public.packs enable row level security;
alter table public.pack_questions enable row level security;
alter table public.pack_deals enable row level security;
alter table public.user_badges enable row level security;
drop policy if exists "read badges" on public.badges;
create policy "read badges" on public.badges for select to authenticated using (true);
drop policy if exists "read packs" on public.packs;
create policy "read packs" on public.packs for select to authenticated using (true);
drop policy if exists "read pack questions" on public.pack_questions;
create policy "read pack questions" on public.pack_questions for select to authenticated using (true);
drop policy if exists "own pack deals" on public.pack_deals;
create policy "own pack deals" on public.pack_deals for select to authenticated using (user_id = auth.uid());
drop policy if exists "own badges" on public.user_badges;
create policy "own badges" on public.user_badges for select to authenticated using (user_id = auth.uid());

-- Read-only from the app: packs are only dealt and finished by the functions below.
revoke all on public.badges, public.packs, public.pack_questions, public.pack_deals, public.user_badges from anon;
revoke insert, update, delete, truncate on public.badges, public.packs, public.pack_questions, public.pack_deals,
  public.user_badges from authenticated;

alter table public.statements add column if not exists via_pack boolean not null default false;  -- answered in a pack; outside the daily 5

-- Own answers today, split into the daily question and the rest. Pack answers
-- don't count, the same as answers to friends' questions.
create or replace function public.answers_used_today(p_user uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'daily_done', exists (
      select 1 from public.statements s join public.questions q on q.id = s.question_id
       where s.user_id = p_user and q.daily_date = public.today_uk()),
    'others', (select count(*) from public.statements s join public.questions q on q.id = s.question_id
                where s.user_id = p_user and s.source = 'app' and s.replaces is null and not s.via_challenge
                  and not s.via_pack
                  and s.created_at >= public.uk_day_start()
                  and q.daily_date is distinct from public.today_uk()),
    'changes', (select count(*) from public.statements
                 where user_id = p_user and source = 'app' and replaces is not null
                   and created_at >= public.uk_day_start()))
$$;

-- Marks every pack someone has answered all of as finished, and gives them
-- its badge. A pack whose questions have all been taken down never finishes.
create or replace function public.finish_packs(p_user uuid) returns void
language sql security definer set search_path = '' as $$
  with done as (
    update public.pack_deals d set finished_at = now()
     where d.user_id = p_user and d.finished_at is null
       and exists (select 1 from public.pack_questions pq join public.questions q on q.id = pq.question_id
                    where pq.pack_id = d.pack_id and q.status = 'approved')
       and not exists (select 1 from public.pack_questions pq join public.questions q on q.id = pq.question_id
                        where pq.pack_id = d.pack_id and q.status = 'approved'
                          and not exists (select 1 from public.statements s
                                           where s.user_id = p_user and s.question_id = pq.question_id
                                             and s.superseded_at is null))
    returning d.pack_id
  )
  insert into public.user_badges (user_id, badge)
  select p_user, p.badge from done join public.packs p on p.id = done.pack_id where p.badge is not null
  on conflict do nothing
$$;

-- The pack in today's hand, dealing the next one when it's due.
create or replace function public.todays_pack() returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); pid bigint;
begin
  perform public.finish_packs(uid);
  -- The pack you're on: one you haven't finished, or one you finished today.
  select d.pack_id into pid from public.pack_deals d join public.packs p on p.id = d.pack_id
   where d.user_id = uid and p.active and (d.finished_at is null or d.finished_at >= public.uk_day_start())
   order by d.finished_at is not null, d.dealt_on desc
   limit 1;
  -- Otherwise the next pack for you, at most one new one a day.
  if pid is null and not exists (select 1 from public.pack_deals where user_id = uid and dealt_on = public.today_uk()) then
    select p.id into pid from public.packs p
     where p.active
       and (p.star_sign is null
            or p.star_sign = (select public.star_sign(pr.birth_date) from public.profiles pr where pr.id = uid))
       and not exists (select 1 from public.pack_deals d where d.user_id = uid and d.pack_id = p.id)
       and exists (select 1 from public.pack_questions pq join public.questions q on q.id = pq.question_id
                    where pq.pack_id = p.id and q.status = 'approved')
     order by p.position, p.id
     limit 1;
    if pid is not null then
      insert into public.pack_deals (user_id, pack_id) values (uid, pid) on conflict do nothing;
    end if;
  end if;
  if pid is null then return null; end if;
  return (select json_build_object(
            'id', p.id, 'slug', p.slug, 'name', p.name, 'blurb', p.blurb,
            'sign', initcap(p.star_sign), 'badge', b.name, 'badge_slug', p.badge,
            'dealt_on', d.dealt_on, 'finished', d.finished_at is not null,
            'questions', (select coalesce(json_agg(json_build_object('id', pq.question_id, 'typical', pq.typical)
                                                   order by pq.position), '[]')
                            from public.pack_questions pq join public.questions q on q.id = pq.question_id
                           where pq.pack_id = p.id and q.status = 'approved'))
          from public.packs p
          join public.pack_deals d on d.pack_id = p.id and d.user_id = uid
          left join public.badges b on b.slug = p.badge
         where p.id = pid);
end $$;

-- answer(): a question in a pack you've been dealt doesn't use up the daily
-- five, and answering the last one finishes the pack. Otherwise as before.
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
  for_friends boolean;
  in_pack boolean;
  used json;
  bonus json;
  ch record;
begin
  select * into q from public.questions
   where id = p_question and status = 'approved' and not is_event
     and (daily_date is null or daily_date <= public.today_uk());
  if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
  is_daily := q.daily_date is not distinct from public.today_uk();
  for_friends := q.audience = 'friends';

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
  if vis = 'public' and (for_friends or not public.is_adult(uid)) then vis := 'friends'; end if;

  used := public.answers_used_today(uid);
  bonus := public.power_bonus(uid);

  if had then
    if cur.verified then raise exception 'This answer was verified by %; change it there', cur.source; end if;
    if (used->>'changes')::int >= public.cfg('changes_per_day') + (bonus->>'changes_used')::int then
      if public.pocket_use(uid, 'second_thoughts', p_question) is null then
        raise exception 'You have used today''s change of mind';
      end if;
    end if;
    update public.statements set superseded_at = now() where id = cur.id;
    insert into public.statements (user_id, question_id, value, visibility, replaces, hidden_until)
    values (uid, p_question, p_value, vis, cur.id,
            now() + make_interval(days => public.cfg('change_hidden_days')));
    return public.question_split(p_question);
  end if;

  -- A question a friend sent you, still on the clock, doesn't use up the daily five.
  -- Neither does any question a friend wrote, or one in a pack you've been dealt.
  challenged := exists (select 1 from public.challenges
                         where to_user = uid and question_id = p_question
                           and answered_at is null and expires_at > now());
  in_pack := exists (select 1 from public.pack_deals d join public.pack_questions pq on pq.pack_id = d.pack_id
                      where d.user_id = uid and pq.question_id = p_question);

  if not is_daily and not challenged and not for_friends and not in_pack
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 + (bonus->>'answers')::int then
    raise exception 'That''s your answers for today. One is always kept for the daily question, so come back tomorrow';
  end if;

  insert into public.statements (user_id, question_id, value, visibility, via_challenge, via_pack)
  values (uid, p_question, p_value, vis, (challenged or for_friends) and not is_daily, in_pack and not is_daily);

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

  if is_daily then perform public.settle_called_it(uid, p_question); end if;
  if in_pack then perform public.finish_packs(uid); end if;

  return public.question_split(p_question);
end $$;

-- The daily slot never picks a pack question.
create or replace function public.ensure_daily() returns void
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  foreach d in array array[public.today_uk(), public.today_uk() + 1] loop
    if not exists (select 1 from public.questions where daily_date = d and status = 'approved') then
      begin
        update public.questions set daily_date = null where daily_date = d;
        update public.questions set daily_date = d
         where id = (select q.id from public.questions q
                      where q.status = 'approved' and q.sensitivity = 'standard' and not q.is_event
                        and q.audience = 'public' and q.daily_date is null
                        and not exists (select 1 from public.pack_questions pq where pq.question_id = q.id)
                      order by q.id limit 1);
      exception when unique_violation then null;  -- someone else filled it at the same moment
      end;
    end if;
  end loop;
end $$;

-- Hot ones leave pack questions out: everyone with that star sign answers them.
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
     and not exists (select 1 from public.pack_questions pq where pq.question_id = q.id)
     and public.can_see_question(auth.uid(), q)
   order by sc.score desc, sc.people desc, q.id
   limit public.cfg('hot_count')
$$;

-- A guest hand from a link leaves pack questions out, unless one is the linked question.
create or replace function public.guest_can_answer(q public.questions, p_linked bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select q.status = 'approved' and not q.is_event and q.sensitivity <> 'sensitive'
     and (q.daily_date is null or q.daily_date <= public.today_uk())
     and case when q.id = p_linked then true
              else q.audience = 'public' and q.daily_date is distinct from public.today_uk()
                   and not exists (select 1 from public.pack_questions pq where pq.question_id = q.id) end
$$;

-- Download my data: now with packs and badges.
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
    'power_ups', (select coalesce(json_agg(json_build_object('day', pu.day, 'card', k.name, 'slashes', k.slashes,
                                                            'claimed_at', pu.claimed_at) order by pu.day), '[]')
                    from public.powerups pu join public.powerup_kinds k on k.kind = pu.kind where pu.user_id = auth.uid()),
    'pocket', (select coalesce(json_agg(json_build_object('card', k.name, 'got_at', pk.got_at, 'used_at', pk.used_at,
                                                         'used_on', q.text, 'guess', pk.guess, 'result', pk.result,
                                                         'won', pk.won, 'became', pk.became) order by pk.got_at), '[]')
                 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                 left join public.questions q on q.id = pk.question_id
                where pk.user_id = auth.uid()),
    'packs', (select coalesce(json_agg(json_build_object('pack', p.name, 'dealt_on', d.dealt_on,
                                                        'finished_at', d.finished_at) order by d.dealt_on), '[]')
                from public.pack_deals d join public.packs p on p.id = d.pack_id where d.user_id = auth.uid()),
    'badges', (select coalesce(json_agg(json_build_object('badge', b.name, 'earned_at', ub.earned_at)
                                        order by ub.earned_at), '[]')
                 from public.user_badges ub join public.badges b on b.slug = ub.badge where ub.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.star_sign(date), public.finish_packs(uuid) from public, anon, authenticated;
revoke execute on function public.todays_pack() from public, anon;
grant execute on function public.todays_pack() to authenticated;

-- The twelve starter packs, five questions each. The questions never name the
-- sign, so an answer on someone's profile doesn't give their birthday away.
insert into public.badges (slug, name, blurb) values
  ('aries', 'Aries', 'Finished the Aries Starter Pack.'),
  ('taurus', 'Taurus', 'Finished the Taurus Starter Pack.'),
  ('gemini', 'Gemini', 'Finished the Gemini Starter Pack.'),
  ('cancer', 'Cancer', 'Finished the Cancer Starter Pack.'),
  ('leo', 'Leo', 'Finished the Leo Starter Pack.'),
  ('virgo', 'Virgo', 'Finished the Virgo Starter Pack.'),
  ('libra', 'Libra', 'Finished the Libra Starter Pack.'),
  ('scorpio', 'Scorpio', 'Finished the Scorpio Starter Pack.'),
  ('sagittarius', 'Sagittarius', 'Finished the Sagittarius Starter Pack.'),
  ('capricorn', 'Capricorn', 'Finished the Capricorn Starter Pack.'),
  ('aquarius', 'Aquarius', 'Finished the Aquarius Starter Pack.'),
  ('pisces', 'Pisces', 'Finished the Pisces Starter Pack.')
on conflict (slug) do nothing;

insert into public.packs (slug, name, blurb, star_sign, badge, position) values
  ('aries-starter', 'Aries Starter Pack', 'For everyone born 21 March to 19 April. Five questions to see how Aries you really are.', 'aries', 'aries', 10),
  ('taurus-starter', 'Taurus Starter Pack', 'For everyone born 20 April to 20 May. Five questions to see how Taurus you really are.', 'taurus', 'taurus', 10),
  ('gemini-starter', 'Gemini Starter Pack', 'For everyone born 21 May to 20 June. Five questions to see how Gemini you really are.', 'gemini', 'gemini', 10),
  ('cancer-starter', 'Cancer Starter Pack', 'For everyone born 21 June to 22 July. Five questions to see how Cancer you really are.', 'cancer', 'cancer', 10),
  ('leo-starter', 'Leo Starter Pack', 'For everyone born 23 July to 22 August. Five questions to see how Leo you really are.', 'leo', 'leo', 10),
  ('virgo-starter', 'Virgo Starter Pack', 'For everyone born 23 August to 22 September. Five questions to see how Virgo you really are.', 'virgo', 'virgo', 10),
  ('libra-starter', 'Libra Starter Pack', 'For everyone born 23 September to 22 October. Five questions to see how Libra you really are.', 'libra', 'libra', 10),
  ('scorpio-starter', 'Scorpio Starter Pack', 'For everyone born 23 October to 21 November. Five questions to see how Scorpio you really are.', 'scorpio', 'scorpio', 10),
  ('sagittarius-starter', 'Sagittarius Starter Pack', 'For everyone born 22 November to 21 December. Five questions to see how Sagittarius you really are.', 'sagittarius', 'sagittarius', 10),
  ('capricorn-starter', 'Capricorn Starter Pack', 'For everyone born 22 December to 19 January. Five questions to see how Capricorn you really are.', 'capricorn', 'capricorn', 10),
  ('aquarius-starter', 'Aquarius Starter Pack', 'For everyone born 20 January to 18 February. Five questions to see how Aquarius you really are.', 'aquarius', 'aquarius', 10),
  ('pisces-starter', 'Pisces Starter Pack', 'For everyone born 19 February to 20 March. Five questions to see how Pisces you really are.', 'pisces', 'pisces', 10)
on conflict (slug) do nothing;

-- typical: the answer the sign is known for, used for "you answered like a
-- typical Libra on 4 of 5" once the pack is finished.
with src (n, sign, pos, text, typical) as (values
  (1, 'aries', 1, 'Do you hate waiting in a queue more than almost anything?', true),
  (1, 'aries', 2, 'Would you rather lead the group than follow it?', true),
  (1, 'aries', 3, 'Have you ever bought something big on a whim?', true),
  (1, 'aries', 4, 'Do you turn everyday things into a competition?', true),
  (1, 'aries', 5, 'Do you think things through before you jump in?', false),
  (2, 'taurus', 1, 'Is a good meal the best part of your day?', true),
  (2, 'taurus', 2, 'Do you order the same thing every time at your favourite place?', true),
  (2, 'taurus', 3, 'Once you''ve made up your mind, is it hard to change it?', true),
  (2, 'taurus', 4, 'Would you pay extra for really comfy bedding?', true),
  (2, 'taurus', 5, 'Do you enjoy last-minute plans?', false),
  (3, 'gemini', 1, 'Do you have at least three hobbies on the go?', true),
  (3, 'gemini', 2, 'Could you chat to a stranger for an hour without running out of things to say?', true),
  (3, 'gemini', 3, 'Do you get bored doing the same thing two days running?', true),
  (3, 'gemini', 4, 'Do your friends say you have two sides to you?', true),
  (3, 'gemini', 5, 'Do you stick to a plan once you''ve made it?', false),
  (4, 'cancer', 1, 'Do you keep old tickets, letters or photos for the memories?', true),
  (4, 'cancer', 2, 'Is a night in at home better than a night out?', true),
  (4, 'cancer', 3, 'Do you cry at films?', true),
  (4, 'cancer', 4, 'Are you the one who looks after everyone at a party?', true),
  (4, 'cancer', 5, 'Do you find it easy to let go of the past?', false),
  (5, 'leo', 1, 'Do you secretly love being the centre of attention?', true),
  (5, 'leo', 2, 'Would you sing karaoke in front of strangers?', true),
  (5, 'leo', 3, 'Do you go all out for your birthday?', true),
  (5, 'leo', 4, 'Are you usually first to get a round in?', true),
  (5, 'leo', 5, 'Do you find it easy to admit you were wrong?', false),
  (6, 'virgo', 1, 'Do you make a to-do list most days?', true),
  (6, 'virgo', 2, 'Does a messy kitchen get on your nerves?', true),
  (6, 'virgo', 3, 'Do you spot spelling mistakes everywhere you look?', true),
  (6, 'virgo', 4, 'Do you read the instructions before you start?', true),
  (6, 'virgo', 5, 'Are you happy to leave a job half done?', false),
  (7, 'libra', 1, 'Do you take ages to choose from a menu?', true),
  (7, 'libra', 2, 'Would you rather keep the peace than win an argument?', true),
  (7, 'libra', 3, 'Do you move things round a room until it looks just right?', true),
  (7, 'libra', 4, 'Can you usually see both sides of an argument?', true),
  (7, 'libra', 5, 'Would you happily eat out on your own?', false),
  (8, 'scorpio', 1, 'Can you keep a secret forever?', true),
  (8, 'scorpio', 2, 'Do you hold a grudge for years?', true),
  (8, 'scorpio', 3, 'Can you read people within minutes of meeting them?', true),
  (8, 'scorpio', 4, 'Have you ever looked someone up online before a first date?', true),
  (8, 'scorpio', 5, 'Do you share everything on social media?', false),
  (9, 'sagittarius', 1, 'Would you book a flight tomorrow if it was cheap enough?', true),
  (9, 'sagittarius', 2, 'Do you say what you think, even when you shouldn''t?', true),
  (9, 'sagittarius', 3, 'Would you rather spend money on experiences than things?', true),
  (9, 'sagittarius', 4, 'Do plans made weeks ahead make you feel trapped?', true),
  (9, 'sagittarius', 5, 'Do you worry about things that might go wrong?', false),
  (10, 'capricorn', 1, 'Do you have a five-year plan?', true),
  (10, 'capricorn', 2, 'Do you check work emails on holiday?', true),
  (10, 'capricorn', 3, 'Do you save more than you spend?', true),
  (10, 'capricorn', 4, 'Were you called mature for your age as a kid?', true),
  (10, 'capricorn', 5, 'Do you leave things to the last minute?', false),
  (11, 'aquarius', 1, 'Do you like being a bit different from everyone else?', true),
  (11, 'aquarius', 2, 'Do you need lots of time to yourself?', true),
  (11, 'aquarius', 3, 'Would you sign up for a trip to Mars?', true),
  (11, 'aquarius', 4, 'Would you rather talk about big ideas than gossip?', true),
  (11, 'aquarius', 5, 'Do you usually follow the latest trends?', false),
  (12, 'pisces', 1, 'Do you daydream a lot?', true),
  (12, 'pisces', 2, 'Do you pick up on other people''s moods as if they were your own?', true),
  (12, 'pisces', 3, 'Do you trust your gut over the facts?', true),
  (12, 'pisces', 4, 'Do you have a creative hobby, like drawing, music or writing?', true),
  (12, 'pisces', 5, 'Do you find it easy to say no to people?', false)
),
added as (
  insert into public.questions (text, category, sensitivity)
  select s.text, 'Star signs', 'standard' from src s
   where not exists (select 1 from public.questions q where q.text = s.text and q.category = 'Star signs')
   order by s.n, s.pos
  returning id, text
),
qs as (
  select id, text from added
  union all
  select id, text from public.questions where category = 'Star signs'
)
insert into public.pack_questions (pack_id, question_id, position, typical)
select p.id, qs.id, s.pos, s.typical
  from src s
  join public.packs p on p.slug = s.sign || '-starter'
  join qs on qs.text = s.text
on conflict do nothing;

notify pgrst, 'reload schema';
