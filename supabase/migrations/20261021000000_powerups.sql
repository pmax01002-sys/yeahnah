-- Power-up cards. The first hand of the day sometimes includes one. For now
-- each power-up holds slashes to claim, and rarer ones hold more. Effect cards
-- can be added later as new rows in powerup_kinds.
--
--   powerup_chance (app_config): percent of days that come with a power-up.
--   powerup_kinds.weight: relative odds of each card when there is one.
--
-- Safe to run twice.

insert into public.app_config (key, value) values ('powerup_chance', 50) on conflict (key) do nothing;

create table if not exists public.powerup_kinds (
  kind text primary key,
  name text not null,
  rarity text not null check (rarity in ('common', 'uncommon', 'rare', 'epic', 'legendary')),
  weight int not null check (weight >= 0),
  slashes int not null default 0 check (slashes >= 0),
  blurb text not null
);
alter table public.powerup_kinds enable row level security;
drop policy if exists "read powerup kinds" on public.powerup_kinds;
create policy "read powerup kinds" on public.powerup_kinds for select to authenticated using (true);

insert into public.powerup_kinds (kind, name, rarity, weight, slashes, blurb) values
  ('loose_change', 'Loose change', 'common', 50, 1, 'Found down the back of the sofa.'),
  ('pocket_money', 'Pocket money', 'uncommon', 25, 2, 'Someone was feeling generous.'),
  ('lucky_find', 'Lucky find', 'rare', 15, 3, 'Was it there yesterday? Who knows.'),
  ('windfall', 'Windfall', 'epic', 8, 5, 'The wind blew in your direction for once.'),
  ('golden_slash', 'Golden slash', 'legendary', 2, 10, 'The rarest card in the deck.')
on conflict (kind) do nothing;

-- One row per person per UK day, made the first time the app asks. kind is
-- null on days without a power-up, so every device sees the same thing.
create table if not exists public.powerups (
  user_id uuid not null references public.profiles (id) on delete cascade,
  day date not null,
  kind text references public.powerup_kinds (kind),
  claimed_at timestamptz,
  primary key (user_id, day)
);
alter table public.powerups enable row level security;
drop policy if exists "own powerups" on public.powerups;
create policy "own powerups" on public.powerups for select to authenticated using (user_id = auth.uid());

-- Read-only from the app: power-ups are only drawn and claimed by the functions below.
revoke all on public.powerups, public.powerup_kinds from anon;
revoke insert, update, delete on public.powerups, public.powerup_kinds from authenticated;

-- Today's power-up, if there is one. The odds are drawn once a day, server side.
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
                                   'blurb', k.blurb, 'claimed', p.claimed_at is not null,
                                   'odds', round(100.0 * k.weight / nullif((select sum(weight) from public.powerup_kinds), 0)))
            from public.powerup_kinds k where k.kind = p.kind);
end $$;

-- Claim today's power-up. Unclaimed ones are gone at midnight.
create or replace function public.claim_powerup() returns int
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); k text; amount int;
begin
  update public.powerups set claimed_at = now()
   where user_id = uid and day = public.today_uk() and kind is not null and claimed_at is null
  returning kind into k;
  if k is null then raise exception 'There''s nothing to claim today'; end if;
  select slashes into amount from public.powerup_kinds where kind = k;
  if amount > 0 then
    insert into public.credit_ledger (user_id, amount, reason) values (uid, amount, 'powerup');
  end if;
  return amount;
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
    'power_ups', (select coalesce(json_agg(json_build_object('day', pu.day, 'card', k.name, 'slashes', k.slashes,
                                                            'claimed_at', pu.claimed_at) order by pu.day), '[]')
                    from public.powerups pu join public.powerup_kinds k on k.kind = pu.kind where pu.user_id = auth.uid()),
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

revoke execute on function public.todays_powerup(), public.claim_powerup() from public, anon;
grant execute on function public.todays_powerup(), public.claim_powerup() to authenticated;

notify pgrst, 'reload schema';
