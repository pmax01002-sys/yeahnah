-- Stars: mark questions in the Questions tab and they're dealt into your
-- Today hand first. Only you can see your own stars, and they're part of
-- "Download my data".
--
-- Safe to run twice.

create table if not exists public.stars (
  user_id uuid not null references public.profiles (id) on delete cascade,
  question_id bigint not null references public.questions (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, question_id)
);
alter table public.stars enable row level security;
drop policy if exists "own stars" on public.stars;
create policy "own stars" on public.stars for select to authenticated using (user_id = auth.uid());

create or replace function public.set_star(p_question bigint, p_on boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_profile(); q public.questions;
begin
  if p_on then
    select * into q from public.questions where id = p_question;
    if not found or not public.can_see_question(uid, q) then raise exception 'Question not found'; end if;
    insert into public.stars (user_id, question_id) values (uid, p_question) on conflict do nothing;
  else
    delete from public.stars where user_id = uid and question_id = p_question;
  end if;
end $$;
revoke execute on function public.set_star(bigint, boolean) from public, anon;
grant execute on function public.set_star(bigint, boolean) to authenticated;

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
    'reports', (select coalesce(json_agg(r), '[]') from public.reports r where reporter = auth.uid()),
    'feedback', (select coalesce(json_agg(json_build_object('body', f.body, 'context', f.context,
                                                            'created_at', f.created_at)), '[]')
                   from public.feedback f where user_id = auth.uid()))
$$;

notify pgrst, 'reload schema';
