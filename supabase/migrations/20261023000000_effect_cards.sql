-- Effect cards: power-ups that do something instead of holding slashes. They
-- come from the same daily draw as the slash cards, one tier of rarity each.
-- Claiming one ("Keep it") puts it in your pocket until midnight (Wildcard:
-- 7 days), and it's used from the question it works on:
--
--   Second thoughts  common     an extra change of mind today (used when you change an answer)
--   Free post        common     your next send is free, even to a whole group
--   Peek             uncommon   see the crowd split on a question before answering
--   Overtime         uncommon   an extra hour on a question a friend sent you
--   Mind reader      rare       see how friends answered a question before answering
--   Extra hand       rare       3 more cards today, with 3 more answers (used straight away)
--   Called it        epic       guess today's split before voting: within 5 points wins 10 slashes
--   Wildcard         legendary  turns into any other card you pick
--
-- Every effect is checked here on the server. Settings in app_config:
--   called_it_prize 10, called_it_window 5, called_it_min_answers 3,
--   overtime_minutes 60, extra_hand_cards 3, free_post_minutes 5.
--
-- Safe to run twice.

insert into public.app_config (key, value) values
  ('called_it_prize', 10), ('called_it_window', 5), ('called_it_min_answers', 3),
  ('overtime_minutes', 60), ('extra_hand_cards', 3), ('free_post_minutes', 5)
on conflict (key) do nothing;

alter table public.powerup_kinds add column if not exists effect text;                 -- null for slash cards
alter table public.powerup_kinds add column if not exists keeps_days int not null default 1;  -- 1 = until midnight

-- Make room for the effect cards: each rarity keeps its share of the draw
-- (50/25/15/8/2), now split between slash and effect cards. Only weights
-- still at their first values change, so tuned ones are left alone.
update public.powerup_kinds k set weight = v.new
  from (values ('loose_change', 50, 20), ('pocket_money', 25, 9), ('lucky_find', 15, 5),
               ('windfall', 8, 4), ('golden_slash', 2, 1)) v (kind, old, new)
 where k.kind = v.kind and k.weight = v.old
   and not exists (select 1 from public.powerup_kinds where effect is not null);

insert into public.powerup_kinds (kind, name, rarity, weight, slashes, blurb, effect, keeps_days) values
  ('second_thoughts', 'Second thoughts', 'common', 15, 0, 'Everyone deserves one more go.', 'second_thoughts', 1),
  ('free_post', 'Free post', 'common', 15, 0, 'First class, no stamp.', 'free_post', 1),
  ('peek', 'Peek', 'uncommon', 8, 0, 'Just a little look.', 'peek', 1),
  ('overtime', 'Overtime', 'uncommon', 8, 0, 'The ref has added time.', 'overtime', 1),
  ('mind_reader', 'Mind reader', 'rare', 5, 0, 'You had a feeling.', 'mind_reader', 1),
  ('extra_hand', 'Extra hand', 'rare', 5, 0, 'Deal me in.', 'extra_hand', 1),
  ('called_it', 'Called it', 'epic', 4, 0, 'Trust your gut.', 'called_it', 1),
  ('wildcard', 'Wildcard', 'legendary', 1, 0, 'The joker in the pack.', 'wildcard', 7)
on conflict (kind) do nothing;

-- Kept effect cards. A row is used once used_at is set; question_id is what it
-- was used on. Called it keeps the guess, the real split and what it won.
create table if not exists public.pocket (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null references public.powerup_kinds (kind),
  got_at timestamptz not null default now(),
  expires_on date not null,                 -- the last UK day it can be used
  used_at timestamptz,
  question_id bigint references public.questions (id) on delete set null,
  guess int,                                -- Called it: % yeah guessed
  result int,                               -- Called it: % yeah among everyone else
  won int,                                  -- Called it: slashes won
  became text references public.powerup_kinds (kind)  -- Wildcard: the card picked
);
create index if not exists pocket_user on public.pocket (user_id, expires_on);
alter table public.pocket enable row level security;
drop policy if exists "own pocket" on public.pocket;
create policy "own pocket" on public.pocket for select to authenticated using (user_id = auth.uid());
revoke all on public.pocket from anon;
revoke insert, update, delete on public.pocket from authenticated;

-- Use the card that runs out soonest. Returns its id, or null if there isn't one.
create or replace function public.pocket_use(p_user uuid, p_effect text, p_question bigint) returns bigint
language plpgsql security definer set search_path = '' as $$
declare pid bigint;
begin
  select pk.id into pid from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
   where pk.user_id = p_user and k.effect = p_effect and pk.used_at is null and pk.expires_on >= public.today_uk()
   order by pk.expires_on, pk.id limit 1
   for update of pk;
  if pid is not null then
    update public.pocket set used_at = now(), question_id = p_question where id = pid;
  end if;
  return pid;
end $$;

create or replace function public.power_used_on(p_user uuid, p_effect text, p_question bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                  where pk.user_id = p_user and k.effect = p_effect and pk.question_id = p_question
                    and pk.used_at is not null)
$$;

-- What today's cards add: answers from Extra hand, and changes of mind from
-- Second thoughts (both used today and still in your pocket).
create or replace function public.power_bonus(p_user uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'answers', public.cfg('extra_hand_cards') * count(*) filter (where k.effect = 'extra_hand' and pk.used_at >= public.uk_day_start()),
    'changes', count(*) filter (where k.effect = 'second_thoughts'
                                  and (pk.used_at >= public.uk_day_start() or (pk.used_at is null and pk.expires_on >= public.today_uk()))),
    'changes_used', count(*) filter (where k.effect = 'second_thoughts' and pk.used_at >= public.uk_day_start()))
  from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
  where pk.user_id = p_user
$$;

-- Today's power-up, now saying whether it's an effect card.
create or replace function public.todays_powerup() returns json
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); k text; p public.powerups;
begin
  select * into p from public.powerups where user_id = uid and day = public.today_uk();
  if not found then
    if random() * 100 < public.cfg('powerup_chance') then
      -- Weighted draw: the smallest -ln(u)/weight wins with odds weight/total.
      select kind into k from public.powerup_kinds where weight > 0 order by -ln(1 - random()) / weight limit 1;
    end if;
    insert into public.powerups (user_id, day, kind) values (uid, public.today_uk(), k) on conflict do nothing;
    select * into p from public.powerups where user_id = uid and day = public.today_uk();
  end if;
  if p.kind is null then return null; end if;
  return (select json_build_object('kind', k.kind, 'name', k.name, 'rarity', k.rarity, 'slashes', k.slashes,
                                   'blurb', k.blurb, 'effect', k.effect, 'keeps_days', k.keeps_days,
                                   'claimed', p.claimed_at is not null,
                                   'odds', round(100.0 * k.weight / nullif((select sum(weight) from public.powerup_kinds), 0)))
            from public.powerup_kinds k where k.kind = p.kind);
end $$;

-- Claim today's power-up: slashes go to your balance, effect cards to your
-- pocket. Extra hand is used as soon as it's kept. Returns the slashes added.
create or replace function public.claim_powerup() returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); kk text; k public.powerup_kinds;
begin
  update public.powerups set claimed_at = now()
   where user_id = uid and day = public.today_uk() and kind is not null and claimed_at is null
  returning kind into kk;
  if kk is null then raise exception 'There''s nothing to claim today'; end if;
  select * into k from public.powerup_kinds where kind = kk;
  if k.effect is not null then
    insert into public.pocket (user_id, kind, expires_on, used_at)
    values (uid, kk, public.today_uk() + greatest(k.keeps_days, 1) - 1, case when k.effect = 'extra_hand' then now() end);
    return 0;
  end if;
  if k.slashes > 0 then
    insert into public.credit_ledger (user_id, amount, reason) values (uid, k.slashes, 'powerup');
  end if;
  return k.slashes;
end $$;

-- Peek and Mind reader open these up before you've answered.
create or replace function public.question_split(p_question bigint) returns json
language sql stable security definer set search_path = '' as $$
  select case when exists (
      select 1 from public.statements
       where user_id = auth.uid() and question_id = p_question and superseded_at is null)
      or public.power_used_on(auth.uid(), 'peek', p_question)
    then (select json_build_object(
            'yes', count(*) filter (where value),
            'no', count(*) filter (where not value),
            'total', count(*))
          from public.statements
         where question_id = p_question and superseded_at is null)
    else null end
$$;

create or replace function public.friends_answers(p_question bigint)
returns table (handle text, display_name text, value boolean, avatar text)
language sql stable security definer set search_path = '' as $$
  select p.handle, p.display_name, s.value, p.avatar
    from public.statements s
    join public.profiles p on p.id = s.user_id
   where s.question_id = p_question and s.superseded_at is null
     and (s.hidden_until is null or s.hidden_until < now())
     and s.visibility in ('public', 'friends')
     and public.are_friends(auth.uid(), s.user_id)
     and (exists (select 1 from public.statements m
                   where m.user_id = auth.uid() and m.question_id = p_question and m.superseded_at is null)
          or public.power_used_on(auth.uid(), 'mind_reader', p_question))
$$;

-- Called it pays out when you answer today's question, against how everyone
-- else answered. With too few other answers to call, the card comes back and
-- keeps until tomorrow.
create or replace function public.settle_called_it(p_user uuid, p_question bigint) returns void
language plpgsql security definer set search_path = '' as $$
declare r record; yes int; total int; pct int; prize int;
begin
  for r in select pk.id, pk.guess from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
            where pk.user_id = p_user and k.effect = 'called_it' and pk.question_id = p_question
              and pk.used_at is not null and pk.won is null
            for update of pk
  loop
    select count(*) filter (where value), count(*) into yes, total from public.statements
     where question_id = p_question and superseded_at is null and user_id <> p_user;
    if total < public.cfg('called_it_min_answers') then
      update public.pocket set used_at = null, question_id = null, guess = null,
             expires_on = greatest(expires_on, public.today_uk() + 1)
       where id = r.id;
    else
      pct := round(100.0 * yes / total);
      prize := case when abs(pct - r.guess) <= public.cfg('called_it_window') then public.cfg('called_it_prize') else 0 end;
      update public.pocket set result = pct, won = prize where id = r.id;
      if prize > 0 then
        insert into public.credit_ledger (user_id, amount, reason, question_id) values (p_user, prize, 'powerup', p_question);
      end if;
    end if;
  end loop;
end $$;

-- Use a card from your pocket on a question. Peek and Mind reader return what
-- they show (and showing it again on the same question is free).
create or replace function public.use_power(p_kind text, p_question bigint default null, p_guess int default null, p_pick text default null)
returns json language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions; k public.powerup_kinds; pid bigint; nm text;
begin
  select name into nm from public.powerup_kinds where kind = p_kind and effect = p_kind;
  if nm is null then raise exception 'No such card'; end if;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));

  if p_kind in ('peek', 'mind_reader', 'overtime', 'called_it') then
    select * into q from public.questions where id = p_question;
    if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
    if exists (select 1 from public.statements where user_id = uid and question_id = p_question and superseded_at is null) then
      raise exception 'You''ve already answered that one';
    end if;
  end if;

  if p_kind in ('peek', 'mind_reader') then
    if not public.power_used_on(uid, p_kind, p_question) then
      if public.pocket_use(uid, p_kind, p_question) is null then raise exception 'You don''t have a % card', nm; end if;
    end if;
    if p_kind = 'peek' then return public.question_split(p_question); end if;
    return (select coalesce(json_agg(f), '[]') from public.friends_answers(p_question) f);

  elsif p_kind = 'overtime' then
    if not exists (select 1 from public.challenges where to_user = uid and question_id = p_question
                    and answered_at is null and expires_at > now()) then
      raise exception 'Overtime works on a question a friend sent you, before its timer runs out';
    end if;
    if public.pocket_use(uid, p_kind, p_question) is null then raise exception 'You don''t have an Overtime card'; end if;
    update public.challenges set expires_at = expires_at + make_interval(mins => public.cfg('overtime_minutes'))
     where to_user = uid and question_id = p_question and answered_at is null and expires_at > now();
    return json_build_object('expires_at', (select max(expires_at) from public.challenges
                                             where to_user = uid and question_id = p_question));

  elsif p_kind = 'called_it' then
    if q.daily_date is distinct from public.today_uk() then raise exception 'Called it works on today''s question'; end if;
    if p_guess is null or p_guess not between 0 and 100 then raise exception 'Guess a number from 0 to 100'; end if;
    if public.power_used_on(uid, p_kind, p_question) then raise exception 'You''ve already made your guess'; end if;
    pid := public.pocket_use(uid, p_kind, p_question);
    if pid is null then raise exception 'You don''t have a Called it card'; end if;
    update public.pocket set guess = p_guess where id = pid;
    return json_build_object('guess', p_guess);

  elsif p_kind = 'wildcard' then
    select * into k from public.powerup_kinds where kind = p_pick and effect is distinct from 'wildcard';
    if not found then raise exception 'Pick which card it becomes'; end if;
    pid := public.pocket_use(uid, p_kind, null);
    if pid is null then raise exception 'You don''t have a Wildcard'; end if;
    update public.pocket set became = k.kind where id = pid;
    if k.effect is not null then
      insert into public.pocket (user_id, kind, expires_on, used_at)
      values (uid, k.kind, public.today_uk(), case when k.effect = 'extra_hand' then now() end);
    elsif k.slashes > 0 then
      insert into public.credit_ledger (user_id, amount, reason) values (uid, k.slashes, 'powerup');
    end if;
    return json_build_object('kind', k.kind, 'name', k.name, 'slashes', k.slashes, 'effect', k.effect);
  end if;
  raise exception '% works by itself', nm;
end $$;

-- answer(): Second thoughts allow another change of mind, Extra hand adds
-- answers, and answering today's question settles Called it.
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
  -- Neither does any question a friend wrote.
  challenged := exists (select 1 from public.challenges
                         where to_user = uid and question_id = p_question
                           and answered_at is null and expires_at > now());

  if not is_daily and not challenged and not for_friends
     and (used->>'others')::int >= public.cfg('answers_per_day') - 1 + (bonus->>'answers')::int then
    raise exception 'That''s your answers for today. One is always kept for the daily question, so come back tomorrow';
  end if;

  insert into public.statements (user_id, question_id, value, visibility, via_challenge)
  values (uid, p_question, p_value, vis, (challenged or for_friends) and not is_daily);

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

  return public.question_split(p_question);
end $$;

-- Free post: the next send that would cost slashes is free, and so is sending
-- the same question to anyone else in the next few minutes (a whole group).
create or replace function public.send_challenge(p_handle text, p_question bigint, p_minutes int default 1440)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); target uuid; bal int; cost int;
begin
  if p_minutes not in (1, 60, 1440) then raise exception 'Pick 1 minute, 1 hour or 1 day'; end if;
  select id into target from public.profiles where handle = lower(p_handle);
  if target is null then raise exception 'No one with that handle'; end if;
  if not public.are_friends(uid, target) then
    raise exception 'You can only send questions to friends (people who follow you back)';
  end if;
  if exists (select 1 from public.questions where id = p_question and (sensitivity = 'sensitive' or is_event)) then
    raise exception 'Sensitive questions can''t be sent to friends';
  end if;
  if exists (select 1 from public.questions where id = p_question and audience = 'friends'
               and created_by is distinct from target and not public.are_friends(target, created_by)) then
    raise exception 'Only friends of the person who wrote it can get this question';
  end if;
  if not exists (select 1 from public.statements where user_id = uid and question_id = p_question and superseded_at is null) then
    raise exception 'Answer it yourself first';
  end if;
  if exists (select 1 from public.statements where user_id = target and question_id = p_question and superseded_at is null) then
    raise exception 'They have already answered that one';
  end if;

  -- Passing on a question written for friends is free.
  cost := case when exists (select 1 from public.questions where id = p_question and audience = 'friends')
               then 0 else public.cfg('send_cost') end;
  perform pg_advisory_xact_lock(hashtextextended(uid::text, 0));
  if cost > 0 then
    if exists (select 1 from public.pocket pk join public.powerup_kinds k on k.kind = pk.kind
                where pk.user_id = uid and k.effect = 'free_post' and pk.question_id = p_question
                  and pk.used_at > now() - make_interval(mins => public.cfg('free_post_minutes'))) then
      cost := 0;
    elsif public.pocket_use(uid, 'free_post', p_question) is not null then
      cost := 0;
    end if;
  end if;
  select coalesce(sum(amount), 0) into bal from public.credit_ledger where user_id = uid;
  if bal < cost then raise exception 'Sending costs % slashes', cost; end if;

  insert into public.challenges (from_user, to_user, question_id, expires_at)
  values (uid, target, p_question, now() + make_interval(mins => p_minutes));
  if cost > 0 then
    insert into public.credit_ledger (user_id, amount, reason, question_id)
    values (uid, -cost, 'send', p_question);
  end if;
exception when unique_violation then
  raise exception 'You already sent them that question';
end $$;

create or replace function public.my_profile() returns json
language sql stable security definer set search_path = '' as $$
  with used as (select public.answers_used_today(auth.uid()) as u, public.power_bonus(auth.uid()) as b)
  select json_build_object(
    'id', p.id, 'handle', p.handle, 'display_name', p.display_name, 'avatar', p.avatar,
    'is_adult', public.is_adult(p.id),
    'sensitive_opt_in', p.sensitive_opt_in_at is not null,
    'credits', coalesce((select sum(amount) from public.credit_ledger where user_id = p.id), 0),
    'unlimited', public.has_unlimited_slashes(p.id),
    'daily_done', (u->>'daily_done')::boolean,
    -- one of the five is always kept for the daily question; Extra hand adds more
    'answers_left_today', public.cfg('answers_per_day') + (b->>'answers')::int - (u->>'others')::int
                          - case when (u->>'daily_done')::boolean then 1 else 0 end,
    'other_answers_left_today', public.cfg('answers_per_day') + (b->>'answers')::int - 1 - (u->>'others')::int,
    'changes_left_today', public.cfg('changes_per_day') + (b->>'changes')::int - (u->>'changes')::int,
    'predictions', public.hit_rate(p.id),
    'created_at', p.created_at)
  from public.profiles p, used where p.id = auth.uid()
$$;

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
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.pocket_use(uuid, text, bigint), public.power_used_on(uuid, text, bigint),
  public.power_bonus(uuid), public.settle_called_it(uuid, bigint) from public, anon, authenticated;
revoke execute on function public.use_power(text, bigint, int, text) from public, anon;
grant execute on function public.use_power(text, bigint, int, text) to authenticated;

notify pgrst, 'reload schema';
