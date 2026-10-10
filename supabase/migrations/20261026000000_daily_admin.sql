-- The daily question from the admin area, and a daily slot that can't go empty.
--
--   * admin_set_daily(question, date) makes a question the daily question for
--     today or a later day; admin_set_daily(null, date) clears that day so the
--     bank fills it. admin_create_question writes a new question for everyone,
--     live straight away, to use as a daily question or just for the bank.
--   * admin_daily() lists the last few days and the next two weeks, and says
--     whether the hourly timer (pg_cron) that fills empty days is running.
--   * ensure_daily() now skips a dated question that isn't live (taken down
--     or waiting), so taking down today's question gets it replaced. Anyone
--     signed in can call it: the app does when it finds no question for
--     today, so the day fills even if the timer isn't running.
--   * The audit log records daily question changes too.
--
-- Safe to run twice.

-- Fill today and tomorrow from the bank when they have no live question.
create or replace function public.ensure_daily() returns void
language plpgsql security definer set search_path = '' as $$
declare d date;
begin
  foreach d in array array[public.today_uk(), public.today_uk() + 1] loop
    if not exists (select 1 from public.questions where daily_date = d and status = 'approved') then
      begin
        update public.questions set daily_date = null where daily_date = d;
        update public.questions set daily_date = d
         where id = (select id from public.questions
                      where status = 'approved' and sensitivity = 'standard' and not is_event
                        and audience = 'public' and daily_date is null
                      order by id limit 1);
      exception when unique_violation then null;  -- someone else filled it at the same moment
      end;
    end if;
  end loop;
end $$;
revoke execute on function public.ensure_daily() from public, anon;
grant execute on function public.ensure_daily() to authenticated;

-- Audit: the same as before, plus changes to daily_date.
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
    if new.daily_date is not null and new.created_by is not null then
      insert into public.question_audit (question_id, actor, action, new_value, note)
      values (new.id, auth.uid(), 'daily', jsonb_build_object('daily_date', new.daily_date), note);
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
  if old.daily_date is distinct from new.daily_date then
    insert into public.question_audit (question_id, actor, action, old_value, new_value, note)
    values (new.id, auth.uid(), 'daily',
            jsonb_build_object('daily_date', old.daily_date), jsonb_build_object('daily_date', new.daily_date), note);
  end if;
  return new;
end $$;

-- Make a question the daily question on a day (today or later), or clear the day.
create or replace function public.admin_set_daily(p_question bigint, p_date date, p_note text default null) returns void
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); q public.questions;
begin
  if p_date is null or p_date < public.today_uk() then raise exception 'Pick today or a later day'; end if;
  perform pg_advisory_xact_lock(hashtextextended('daily', 0));
  perform set_config('yeahnah.audit_note', coalesce(trim(p_note), ''), true);
  if p_question is not null then
    select * into q from public.questions where id = p_question for update;
    if not found then raise exception 'No such question'; end if;
    if q.status <> 'approved' or q.audience <> 'public' or q.is_event then
      raise exception 'The daily question has to be a live question for everyone';
    end if;
    if q.daily_date = p_date then return; end if;
    if q.daily_date is not null and q.daily_date < public.today_uk() then
      raise exception 'That was already the daily question on %', to_char(q.daily_date, 'DD Mon');
    end if;
  end if;
  update public.questions set daily_date = null where daily_date = p_date;
  if p_question is not null then
    update public.questions set daily_date = p_date where id = p_question;
  end if;
  perform set_config('yeahnah.audit_note', '', true);
  -- An emptied today or tomorrow is filled from the bank straight away.
  perform public.ensure_daily();
end $$;

-- A new question for everyone, written by an admin: live straight away.
create or replace function public.admin_create_question(p_text text, p_category text default 'General',
  p_sensitivity text default 'standard', p_option_yes text default null, p_option_no text default null) returns bigint
language plpgsql security definer set search_path = '' as $$
declare uid uuid := public.require_admin(); new_id bigint;
begin
  if char_length(trim(coalesce(p_text, ''))) not between 5 and 140 then
    raise exception 'Questions are 5 to 140 characters';
  end if;
  if (nullif(trim(p_option_yes), '') is null) <> (nullif(trim(p_option_no), '') is null) then
    raise exception 'A pick needs both options';
  end if;
  if coalesce(p_sensitivity, 'standard') not in ('standard', 'personal', 'sensitive') then
    raise exception 'Sensitivity is standard, personal or sensitive';
  end if;
  insert into public.questions (text, category, sensitivity, option_yes, option_no, status, audience, created_by,
                                reviewed_by, reviewed_at, review_note)
  values (trim(p_text), coalesce(nullif(trim(p_category), ''), 'General'), coalesce(p_sensitivity, 'standard')::public.sensitivity,
          nullif(trim(p_option_yes), ''), nullif(trim(p_option_no), ''), 'approved', 'public', uid,
          uid, now(), 'Written by an admin')
  returning id into new_id;
  return new_id;
end $$;

-- The daily schedule: the last 3 days, today and the next p_days, plus whether the timer runs.
create or replace function public.admin_daily(p_days int default 14) returns json
language plpgsql stable security definer set search_path = '' as $$
declare timer boolean := false;
begin
  perform public.require_admin();
  if to_regclass('cron.job') is not null then
    execute 'select exists (select 1 from cron.job where jobname = ''ensure-daily'' and active)' into timer;
  end if;
  return json_build_object(
    'today', public.today_uk(),
    'timer', timer,
    'bank_left', (select count(*) from public.questions
                   where status = 'approved' and sensitivity = 'standard' and not is_event
                     and audience = 'public' and daily_date is null),
    'days', (select json_agg(json_build_object(
               'date', d::date,
               'question', (select json_build_object('id', q.id, 'text', q.text, 'category', q.category, 'status', q.status,
                                  'answers', (select count(*) from public.statements s where s.question_id = q.id and s.superseded_at is null))
                              from public.questions q where q.daily_date = d::date))
             order by d)
             from generate_series(public.today_uk() - 3, public.today_uk() + least(greatest(p_days, 1), 60), interval '1 day') d));
end $$;

revoke execute on function public.admin_set_daily(bigint, date, text),
  public.admin_create_question(text, text, text, text, text), public.admin_daily(int)
from public, anon, authenticated;
grant execute on function public.admin_set_daily(bigint, date, text),
  public.admin_create_question(text, text, text, text, text), public.admin_daily(int)
to authenticated;

-- Schedule the hourly timer again, in case it was skipped when the database
-- was set up (pg_cron is on every Supabase project, but may need switching
-- on under Database > Extensions). Re-scheduling the same name just updates it.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('ensure-daily', '0 * * * *', 'select public.ensure_daily()');
  perform cron.schedule('resolve-predictions', '5 * * * *', 'select public.resolve_due()');
exception when others then
  raise notice 'pg_cron not available (%): the app fills empty days itself', sqlerrm;
end $$;

-- Fill today now.
select public.ensure_daily();

notify pgrst, 'reload schema';
