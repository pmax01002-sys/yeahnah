-- Answer before signing up: someone who opens a question link without an
-- account gets a hand of guest_answers (5) questions, the linked one first,
-- and sees how everyone answered each one. The answers stay on their phone
-- until they sign up, then claim_guest_answers saves them to the new profile.
--
-- Saved guest answers have source 'link', so they don't use up the day's
-- answers: a new account still gets its 5 that day. Today's question is only
-- in the guest hand when it's the one that was linked, so it's still there to
-- answer after signing up unless it was already answered from the link.
--
-- Answers can only be claimed once per account, by an account made in the
-- last day, so the daily limit can't be dodged by claiming again.
--
-- Safe to run twice.

insert into public.app_config (key, value) values ('guest_answers', 5) on conflict (key) do nothing;

alter table public.profiles add column if not exists guest_claimed_at timestamptz;

-- Questions a guest can answer from a link: everyday ones that anyone can see,
-- nothing sensitive, and not today's or a future daily question.
create or replace function public.guest_can_answer(q public.questions, p_linked bigint) returns boolean
language sql stable security definer set search_path = '' as $$
  select q.status = 'approved' and not q.is_event and q.sensitivity <> 'sensitive'
     and (q.daily_date is null or q.daily_date <= public.today_uk())
     and case when q.id = p_linked then true
              else q.audience = 'public' and q.daily_date is distinct from public.today_uk() end
$$;
revoke execute on function public.guest_can_answer(public.questions, bigint) from public, anon, authenticated;

-- The guest hand for a link: the linked question first, then the rest picked
-- at random. Needs a working link, so the whole bank can't be read without one.
create or replace function public.guest_hand(p_code text) returns json
language sql stable security definer set search_path = '' as $$
  with link as (
    select l.question_id as id, p.display_name as sharer
      from public.question_links l
      join public.questions q on q.id = l.question_id
      left join public.profiles p on p.id = coalesce(l.shared_by, q.created_by)
     where l.code = trim(p_code)
  ),
  picked as (
    select q.*, 0 as ord from public.questions q, link where q.id = link.id and public.guest_can_answer(q, link.id)
    union all
    (select q.*, 1 from public.questions q, link
      where q.id <> link.id and public.guest_can_answer(q, link.id)
        and exists (select 1 from public.questions lq where lq.id = link.id and public.guest_can_answer(lq, link.id))
      order by random() limit public.cfg('guest_answers') - 1)
  )
  select coalesce(json_agg(json_build_object(
           'id', id, 'text', text, 'category', category, 'sensitivity', sensitivity,
           'option_yes', option_yes, 'option_no', option_no, 'emoji_yes', emoji_yes, 'emoji_no', emoji_no,
           'linked', ord = 0, 'by', case when ord = 0 then (select sharer from link) end)
         order by ord), '[]')
    from picked
$$;
revoke execute on function public.guest_hand(text) from public;
grant execute on function public.guest_hand(text) to anon, authenticated;

-- How everyone answered one of the questions in a link's guest hand.
create or replace function public.guest_split(p_code text, p_question bigint) returns json
language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.question_links l join public.questions q on q.id = p_question
                             where l.code = trim(p_code) and public.guest_can_answer(q, l.question_id))
    then (select json_build_object(
            'yes', count(*) filter (where value),
            'no', count(*) filter (where not value),
            'total', count(*))
          from public.statements where question_id = p_question and superseded_at is null)
    end
$$;
revoke execute on function public.guest_split(text, bigint) from public;
grant execute on function public.guest_split(text, bigint) to anon, authenticated;

-- Saves the answers given before signing up: [{"question_id": 1, "value": true}, ...].
-- Run it after open_question_link, so a friends-only question from the link is
-- visible. Questions the account can't see or has already answered are
-- skipped. Returns how many were saved.
create or replace function public.claim_guest_answers(p_answers jsonb) returns int
language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := public.require_profile();
  me public.profiles;
  a jsonb;
  q public.questions;
  vis public.visibility;
  saved int := 0;
begin
  select * into me from public.profiles where id = uid for update;
  if me.guest_claimed_at is not null or me.created_at < now() - interval '1 day' then return 0; end if;
  update public.profiles set guest_claimed_at = now() where id = uid;
  if jsonb_typeof(p_answers) <> 'array' then return 0; end if;

  for a in select value from jsonb_array_elements(p_answers) limit public.cfg('guest_answers') loop
    select * into q from public.questions where id = (a->>'question_id')::bigint;
    continue when not found or jsonb_typeof(a->'value') <> 'boolean'
      or q.status <> 'approved' or q.is_event or q.sensitivity = 'sensitive'
      or (q.daily_date is not null and q.daily_date > public.today_uk())
      or not public.can_see_question(uid, q)
      or exists (select 1 from public.statements where user_id = uid and question_id = q.id and superseded_at is null);
    vis := case when q.audience = 'public' and q.sensitivity = 'standard' and public.cfg('new_answers_public') = 1
                     and public.is_adult(uid)
                then 'public'::public.visibility else 'friends'::public.visibility end;
    insert into public.statements (user_id, question_id, value, visibility, source)
    values (uid, q.id, (a->>'value')::boolean, vis, 'link');
    saved := saved + 1;
  end loop;
  return saved;
end $$;
revoke execute on function public.claim_guest_answers(jsonb) from public, anon;
grant execute on function public.claim_guest_answers(jsonb) to authenticated;

notify pgrst, 'reload schema';
