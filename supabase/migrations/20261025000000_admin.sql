-- Admin area: review suggested questions, manage the question bank, read
-- feedback and reports, and see who changed what on a question (the audit log).
--
--   * Only accounts listed in public.admins can use it. Every admin_* function
--     checks that on the server, so hiding the button in the app is not what
--     keeps people out. Max's @harley is the first admin.
--   * Add one in the SQL Editor:
--       insert into public.admins (user_id) select id from public.profiles where handle = 'handle';
--     Remove one:
--       delete from public.admins where user_id = (select id from public.profiles where handle = 'handle');
--   * The audit log is written by a trigger on questions, so it also records
--     changes made in the Table Editor or SQL Editor (shown with no person).
--     It covers questions for everyone; friend questions stay between friends
--     unless someone reports one.
--   * Notes an admin leaves on a report or on feedback are part of that row,
--     so the person who sent it sees them in "Download my data".
--
-- Safe to run twice.

create table if not exists public.admins (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;  -- no policies: only is_admin() reads it
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.admins where user_id = auth.uid())
$$;

create or replace function public.require_admin() returns uuid
language plpgsql stable security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists (select 1 from public.admins where user_id = auth.uid()) then
    raise exception 'Only admins can do that' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

-- Who reviewed a question, when, and why.
alter table public.questions add column if not exists reviewed_by uuid references public.profiles (id) on delete set null;
alter table public.questions add column if not exists reviewed_at timestamptz;
alter table public.questions add column if not exists review_note text;

-- Feedback and reports get an inbox status and a note.
alter table public.feedback add column if not exists status text not null default 'open';
do $$ begin
  alter table public.feedback add constraint feedback_status check (status in ('open', 'done'));
exception when duplicate_object then null; end $$;
alter table public.feedback add column if not exists admin_note text;
alter table public.feedback add column if not exists handled_by uuid references public.profiles (id) on delete set null;
alter table public.feedback add column if not exists handled_at timestamptz;
alter table public.reports add column if not exists admin_note text;
alter table public.reports add column if not exists handled_by uuid references public.profiles (id) on delete set null;
alter table public.reports add column if not exists handled_at timestamptz;
create index if not exists feedback_status on public.feedback (status, created_at desc);
create index if not exists reports_status on public.reports (status, created_at desc);

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------

create table if not exists public.question_audit (
  id bigint generated always as identity primary key,
  question_id bigint references public.questions (id) on delete cascade,
  actor uuid references public.profiles (id) on delete set null,  -- null = Table Editor / SQL Editor / a timer
  action text not null,                -- submitted, approved, rejected, reopened, edited
  old_value jsonb,
  new_value jsonb,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists question_audit_question on public.question_audit (question_id, created_at desc);
create index if not exists question_audit_time on public.question_audit (created_at desc);
alter table public.question_audit enable row level security;  -- no policies: read through admin_audit()
revoke all on public.question_audit from anon, authenticated;

-- An admin function passes its note to the trigger through this setting.
create or replace function public.question_audit_trigger() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  note text := nullif(current_setting('yeahnah.audit_note', true), '');
  old_edit jsonb; new_edit jsonb;
begin
  if tg_op = 'INSERT' then
    if new.created_by is not null and new.audience = 'public' then
      insert into public.question_audit (question_id, actor, action, new_value)
      values (new.id, new.created_by, 'submitted',
              jsonb_build_object('text', new.text, 'category', new.category, 'status', new.status));
    end if;
    return new;
  end if;

  old_edit := jsonb_build_object('text', old.text, 'category', old.category, 'sensitivity', old.sensitivity,
                                 'option_yes', old.option_yes, 'option_no', old.option_no);
  new_edit := jsonb_build_object('text', new.text, 'category', new.category, 'sensitivity', new.sensitivity,
                                 'option_yes', new.option_yes, 'option_no', new.option_no);
  if old_edit is distinct from new_edit then
    -- Only the fields that changed.
    select jsonb_object_agg(o.key, o.value), jsonb_object_agg(o.key, new_edit -> o.key)
      into old_edit, new_edit
      from jsonb_each(old_edit) o where o.value is distinct from new_edit -> o.key;
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(), 'edited', old_edit, new_edit, note);
  end if;
  if old.status is distinct from new.status then
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(),
            case new.status when 'approved' then 'approved' when 'rejected' then 'rejected' else 'reopened' end,
            jsonb_build_object('status', old.status), jsonb_build_object('status', new.status), note);
  end if;
  return new;
end $$;
drop trigger if exists question_audit on public.questions;
create trigger question_audit after insert or update on public.questions
  for each row execute function public.question_audit_trigger();

-- Suggestions sent before this update get their "submitted" line once.
insert into public.question_audit (question_id, actor, action, new_value, created_at)
select q.id, q.created_by, 'submitted',
       jsonb_build_object('text', q.text, 'category', q.category, 'status', q.status), q.created_at
  from public.questions q
 where q.created_by is not null and q.audience = 'public'
   and not exists (select 1 from public.question_audit a where a.question_id = q.id and a.action = 'submitted');

-- ---------------------------------------------------------------------------
-- What the admin screens read
-- ---------------------------------------------------------------------------

-- Counts for the badge on the Admin button.
create or replace function public.admin_summary() returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return json_build_object(
    'pending', (select count(*) from public.questions where status = 'pending'),
    'reports', (select count(*) from public.reports where status = 'open'),
    'feedback', (select count(*) from public.feedback where status = 'open'));
end $$;

-- Questions for everyone, newest first. p_status: pending, approved, rejected or null for all.
-- p_people_only = true leaves out the built-in bank (only questions people wrote).
create or replace function public.admin_questions(p_status text default 'pending', p_search text default null,
  p_people_only boolean default false, p_limit int default 50, p_offset int default 0) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select q.id, q.text, q.category, q.sensitivity, q.option_yes, q.option_no, q.status, q.audience,
           q.is_event, q.daily_date, q.created_at, q.reviewed_at, q.review_note,
           (select handle from public.profiles where id = q.reviewed_by) as reviewed_by,
           case when q.created_by is not null then json_build_object(
             'handle', p.handle, 'name', p.display_name, 'joined', p.created_at,
             'approved', (select count(*) from public.questions o where o.created_by = q.created_by and o.audience = 'public' and o.status = 'approved'),
             'rejected', (select count(*) from public.questions o where o.created_by = q.created_by and o.audience = 'public' and o.status = 'rejected'))
           end as author,
           (select count(*) from public.statements s where s.question_id = q.id and s.superseded_at is null) as answers,
           (select count(*) from public.reports r where r.question_id = q.id and r.status = 'open') as open_reports
      from public.questions q
      left join public.profiles p on p.id = q.created_by
     where q.audience = 'public'
       and (p_status is null or q.status = p_status)
       and (not p_people_only or q.created_by is not null)
       and (p_search is null or trim(p_search) = '' or q.text ilike '%' || trim(p_search) || '%'
            or q.category ilike trim(p_search) or p.handle = lower(trim(both '@ ' from p_search)))
     order by q.created_at desc, q.id desc
     limit least(greatest(p_limit, 1), 200) offset greatest(p_offset, 0)) x);
end $$;

-- Change a question: approve, reject, put back to pending, and/or edit it.
-- Rejecting a suggestion can hand back what it cost (p_refund).
create or replace function public.admin_set_question(p_question bigint, p_status text default null,
  p_text text default null, p_category text default null, p_sensitivity text default null,
  p_note text default null, p_refund boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); q public.questions; paid int;
begin
  select * into q from public.questions where id = p_question for update;
  if not found then raise exception 'No such question'; end if;
  if p_status is not null and p_status not in ('pending', 'approved', 'rejected') then
    raise exception 'Status is pending, approved or rejected';
  end if;
  if p_text is not null and char_length(trim(p_text)) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  if p_sensitivity is not null and p_sensitivity not in ('standard', 'personal', 'sensitive') then
    raise exception 'Sensitivity is standard, personal or sensitive';
  end if;

  perform set_config('yeahnah.audit_note', coalesce(trim(p_note), ''), true);
  update public.questions set
    text = coalesce(nullif(trim(p_text), ''), text),
    category = coalesce(nullif(trim(p_category), ''), category),
    sensitivity = coalesce(p_sensitivity::public.sensitivity, sensitivity),
    status = coalesce(p_status, status),
    reviewed_by = case when p_status is not null then uid else reviewed_by end,
    reviewed_at = case when p_status is not null then now() else reviewed_at end,
    review_note = case when p_status is not null then nullif(trim(p_note), '') else review_note end
   where id = p_question;
  perform set_config('yeahnah.audit_note', '', true);

  -- Hand back what the suggestion cost, once.
  if p_refund and p_status = 'rejected' and q.created_by is not null
     and not exists (select 1 from public.credit_ledger where question_id = p_question and reason = 'suggest_refund') then
    select coalesce(-sum(amount), 0) into paid from public.credit_ledger
     where question_id = p_question and user_id = q.created_by and reason = 'suggest';
    if paid > 0 then
      insert into public.credit_ledger (user_id, amount, reason, question_id)
      values (q.created_by, paid, 'suggest_refund', p_question);
      insert into public.question_audit (question_id, actor, action, new_value)
      values (p_question, uid, 'refunded', jsonb_build_object('slashes', paid));
    end if;
  end if;
end $$;

-- The audit log, for one question or for everything.
create or replace function public.admin_audit(p_question bigint default null, p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select a.id, a.question_id, a.action, a.old_value, a.new_value, a.note, a.created_at,
           p.handle as actor, q.text as question
      from public.question_audit a
      left join public.profiles p on p.id = a.actor
      left join public.questions q on q.id = a.question_id
     where p_question is null or a.question_id = p_question
     order by a.created_at desc, a.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

-- Reports about questions or people. A reported friend question's text is shown here,
-- so an admin can check it.
create or replace function public.admin_reports(p_status text default 'open', p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select r.id, r.reason, r.status, r.admin_note, r.created_at, r.handled_at,
           (select handle from public.profiles where id = r.handled_by) as handled_by,
           (select handle from public.profiles where id = r.reporter) as reporter,
           (select handle from public.profiles where id = r.target_user) as target,
           case when q.id is not null then json_build_object('id', q.id, 'text', q.text, 'status', q.status,
             'audience', q.audience, 'by', (select handle from public.profiles where id = q.created_by)) end as question,
           (select count(*) from public.reports o where o.question_id = r.question_id and r.question_id is not null) as reports_on_question
      from public.reports r
      left join public.questions q on q.id = r.question_id
     where p_status is null or r.status = p_status
     order by r.created_at desc, r.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

-- Close a report. p_hide_question also takes the reported question down.
create or replace function public.admin_set_report(p_report bigint, p_status text,
  p_note text default null, p_hide_question boolean default false) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); r public.reports;
begin
  if p_status not in ('open', 'actioned', 'dismissed') then raise exception 'Status is open, actioned or dismissed'; end if;
  update public.reports set status = p_status, admin_note = nullif(trim(p_note), ''),
         handled_by = case when p_status = 'open' then null else uid end,
         handled_at = case when p_status = 'open' then null else now() end
   where id = p_report returning * into r;
  if not found then raise exception 'No such report'; end if;
  if p_hide_question and r.question_id is not null then
    perform public.admin_set_question(r.question_id, 'rejected', p_note => coalesce(nullif(trim(p_note), ''), 'Reported: ' || r.reason));
  end if;
end $$;

create or replace function public.admin_feedback(p_status text default 'open', p_limit int default 100) returns json
language plpgsql stable security definer set search_path = '' as $$
begin
  perform public.require_admin();
  return (select coalesce(json_agg(row_to_json(x) order by x.created_at desc, x.id desc), '[]') from (
    select f.id, f.body, f.context, f.status, f.admin_note, f.created_at, f.handled_at,
           (select handle from public.profiles where id = f.handled_by) as handled_by,
           p.handle, p.display_name as name
      from public.feedback f
      left join public.profiles p on p.id = f.user_id
     where p_status is null or f.status = p_status
     order by f.created_at desc, f.id desc
     limit least(greatest(p_limit, 1), 500)) x);
end $$;

create or replace function public.admin_set_feedback(p_feedback bigint, p_status text, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin();
begin
  if p_status not in ('open', 'done') then raise exception 'Status is open or done'; end if;
  update public.feedback set status = p_status, admin_note = nullif(trim(p_note), ''),
         handled_by = case when p_status = 'done' then uid end,
         handled_at = case when p_status = 'done' then now() end
   where id = p_feedback;
  if not found then raise exception 'No such feedback'; end if;
end $$;

revoke execute on function public.is_admin(), public.require_admin(), public.question_audit_trigger(),
  public.admin_summary(), public.admin_questions(text, text, boolean, int, int),
  public.admin_set_question(bigint, text, text, text, text, text, boolean),
  public.admin_audit(bigint, int), public.admin_reports(text, int),
  public.admin_set_report(bigint, text, text, boolean), public.admin_feedback(text, int),
  public.admin_set_feedback(bigint, text, text)
from public, anon, authenticated;
grant execute on function public.is_admin(),
  public.admin_summary(), public.admin_questions(text, text, boolean, int, int),
  public.admin_set_question(bigint, text, text, text, text, text, boolean),
  public.admin_audit(bigint, int), public.admin_reports(text, int),
  public.admin_set_report(bigint, text, text, boolean), public.admin_feedback(text, int),
  public.admin_set_feedback(bigint, text, text)
to authenticated;

-- Max's own account.
insert into public.admins (user_id) select id from public.profiles where handle = 'harley' on conflict do nothing;

notify pgrst, 'reload schema';
