import React, { useCallback, useEffect, useState } from 'react';
import { call } from './supabase.js';

// ---------------------------------------------------------------------------
// Admin area: only for accounts in public.admins. Every admin_* call is
// checked in the database too, so this screen opening is not the protection.
// ---------------------------------------------------------------------------

const SECTIONS = [['review', 'Review'], ['growth', 'Growth'], ['daily', 'Daily'], ['questions', 'Questions'], ['reports', 'Reports'], ['feedback', 'Feedback'], ['log', 'Audit log']];
const who = h => (h ? `@${h}` : 'the SQL Editor');
const when = t => (t ? new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '');

// Admin button counts, for the top bar. Null for everyone who isn't an admin.
export function useAdminSummary(meId) {
  const [summary, setSummary] = useState(null);
  const refresh = useCallback(async () => {
    try { setSummary(await call('is_admin') ? await call('admin_summary') : null); }
    catch { setSummary(null); }  // before the admin update runs, nobody is an admin
  }, []);
  useEffect(() => { if (meId) refresh(); }, [meId, refresh]);
  return [summary, refresh];
}

function useList(fn, args) {
  const key = JSON.stringify(args);
  const [rows, setRows] = useState(null);
  const [error, setError] = useState('');
  const load = useCallback(async () => {
    setError('');
    try { setRows(await call(fn, JSON.parse(key))); } catch (e) { setError(e.message); }
  }, [fn, key]);
  useEffect(() => { load(); }, [load]);
  return [rows, load, error];
}

function Err({ error }) {
  return error ? <div className="error" role="alert">{error}</div> : null;
}

function Filters({ value, onChange, options }) {
  return (
    <div className="filters" role="group">
      {options.map(([k, label]) => <button key={k ?? 'all'} aria-pressed={value === k} onClick={() => onChange(k)}>{label}</button>)}
    </div>
  );
}

export default function Admin({ summary, onChanged, onClose, themes }) {
  const [section, setSection] = useState('review');
  const [logFor, setLogFor] = useState(null);
  const counts = { review: summary?.pending, reports: summary?.reports, feedback: summary?.feedback };
  const ctx = { onChanged, themes, showLog: q => { setLogFor(q); setSection('log'); } };
  return (
    <>
      <div className="head" style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <h1>Admin</h1>
        <button className="close" onClick={onClose}>Back to the app</button>
      </div>
      <div className="filters" role="tablist" aria-label="Admin sections">
        {SECTIONS.map(([k, label]) => (
          <button key={k} role="tab" aria-pressed={section === k} aria-selected={section === k}
            onClick={() => { setSection(k); if (k !== 'log') setLogFor(null); }}>
            {label}{counts[k] ? ` (${counts[k]})` : ''}
          </button>
        ))}
      </div>
      {section === 'review' && <QuestionList {...ctx} status="pending" key="review" />}
      {section === 'growth' && <Growth />}
      {section === 'daily' && <Daily {...ctx} />}
      {section === 'questions' && <QuestionList {...ctx} key="all" />}
      {section === 'reports' && <Reports {...ctx} />}
      {section === 'feedback' && <Feedback {...ctx} />}
      {section === 'log' && <AuditLog question={logFor} onAll={() => setLogFor(null)} />}
    </>
  );
}

// ---------------------------------------------------------------------------
// Questions: the review queue (pending) and the whole bank
// ---------------------------------------------------------------------------

function QuestionList({ status: fixed, onChanged, themes, showLog }) {
  const reviewing = fixed === 'pending';
  const [status, setStatus] = useState(reviewing ? 'pending' : 'approved');
  const [peopleOnly, setPeopleOnly] = useState(false);
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [rows, load, error] = useList('admin_questions', {
    p_status: reviewing ? 'pending' : status, p_search: query || null, p_people_only: reviewing || peopleOnly, p_limit: 100,
  });
  const changed = async () => { await load(); onChanged(); };
  return (
    <>
      {reviewing
        ? <p className="hint">Questions people suggested for everyone. Approving puts them in everyone's bank; rejecting can hand back the slashes they paid.</p>
        : <>
          <Filters value={status} onChange={setStatus}
            options={[['approved', 'Live'], ['pending', 'Waiting'], ['rejected', 'Rejected'], [null, 'All']]} />
          <form className="inline" onSubmit={e => { e.preventDefault(); setQuery(search.trim()); }}>
            <input type="search" placeholder="Search text, theme or @handle" value={search} onChange={e => setSearch(e.target.value)} />
            <button className="ghost">Search</button>
          </form>
          <label className="hint" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
            <input type="checkbox" checked={peopleOnly} onChange={e => setPeopleOnly(e.target.checked)} /> Only questions people wrote
          </label>
        </>}
      <Err error={error} />
      {rows && rows.length === 0 && <p className="empty">{reviewing ? 'Nothing waiting for review.' : 'No questions match.'}</p>}
      <div className="rows">
        {(rows || []).map(q => <AdminQuestion key={q.id} q={q} themes={themes} onChanged={changed} showLog={showLog} />)}
      </div>
    </>
  );
}

function AdminQuestion({ q, themes, onChanged, showLog }) {
  const [editing, setEditing] = useState(false);
  const [text, setText] = useState(q.text);
  const [category, setCategory] = useState(q.category);
  const [sensitivity, setSensitivity] = useState(q.sensitivity);
  const [note, setNote] = useState('');
  const [refund, setRefund] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function act(status) {
    setError(''); setBusy(true);
    const edits = editing ? {
      p_text: text !== q.text ? text : null,
      p_category: category !== q.category ? category : null,
      p_sensitivity: sensitivity !== q.sensitivity ? sensitivity : null,
    } : {};
    if (editing && q.answers > 0 && edits.p_text
        && !window.confirm(`${q.answers} people have answered this. Changing the words changes what their answers mean. Save anyway?`)) {
      setBusy(false); return;
    }
    try {
      await call('admin_set_question', { p_question: q.id, p_status: status, p_note: note || null,
        p_refund: status === 'rejected' && refund, ...edits });
      setEditing(false); setNote('');
      await onChanged();
    } catch (e) { setError(e.message); }
    setBusy(false);
  }

  const a = q.author;
  return (
    <div className="panel">
      <div className="chips">
        <span className="chip">{q.status === 'pending' ? 'Waiting' : q.status === 'approved' ? 'Live' : 'Rejected'}</span>
        <span className="chip cat">{q.category}</span>
        {q.sensitivity !== 'standard' && <span className={`chip ${q.sensitivity}`}>{q.sensitivity}</span>}
        {q.daily_date && <span className="chip daily">Daily {q.daily_date}</span>}
        {q.is_event && <span className="chip">World event</span>}
        {q.open_reports > 0 && <span className="chip sensitive">{q.open_reports} open report{q.open_reports > 1 ? 's' : ''}</span>}
      </div>
      {editing ? (
        <div className="field">
          <label className="field"><span className="label">Question</span>
            <textarea rows={2} minLength={5} maxLength={140} value={text} onChange={e => setText(e.target.value)} /></label>
          <div className="inline">
            <select aria-label="Theme" value={category} onChange={e => setCategory(e.target.value)}>
              {[...new Set([q.category, ...themes])].map(t => <option key={t}>{t}</option>)}
            </select>
            <select aria-label="Sensitivity" value={sensitivity} onChange={e => setSensitivity(e.target.value)}>
              <option value="standard">Standard</option><option value="personal">Personal</option><option value="sensitive">Sensitive</option>
            </select>
          </div>
        </div>
      ) : <strong>{q.text}</strong>}
      {q.option_yes && <span className="hint">Pick: {q.option_yes} or {q.option_no}</span>}
      <span className="hint">
        {a ? <>By @{a.handle} ({a.name}) · {a.approved} live, {a.rejected} rejected before</> : 'Built-in question'}
        {' · '}{when(q.created_at)} · {q.answers} answer{q.answers === 1 ? '' : 's'}
        {q.reviewed_at && <><br />Reviewed by {who(q.reviewed_by)} {when(q.reviewed_at)}{q.review_note ? `: ${q.review_note}` : ''}</>}
      </span>
      {(editing || q.status === 'pending') && (
        <input aria-label="Note for the audit log" placeholder="Note for the audit log (optional)" value={note} onChange={e => setNote(e.target.value)}
          style={{ border: '1px solid var(--ink)', padding: '6px 8px', background: 'var(--surface)' }} />
      )}
      {a && q.status === 'pending' && (
        <label className="hint" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
          <input type="checkbox" checked={refund} onChange={e => setRefund(e.target.checked)} /> If rejected, give @{a.handle} their slashes back
        </label>
      )}
      <Err error={error} />
      <div className="inline" style={{ flexWrap: 'wrap' }}>
        {q.status !== 'approved' && <button className="solid" disabled={busy} onClick={() => act('approved')}>{editing ? 'Save and approve' : 'Approve'}</button>}
        {q.status !== 'rejected' && <button className="ghost danger" disabled={busy} onClick={() => act('rejected')}>{q.status === 'approved' ? 'Take down' : 'Reject'}</button>}
        {q.status === 'rejected' && <button className="ghost" disabled={busy} onClick={() => act('pending')}>Back to review</button>}
        {editing
          ? <><button className="ghost" disabled={busy} onClick={() => act(null)}>Save edits</button>
            <button className="ghost" onClick={() => { setEditing(false); setText(q.text); setCategory(q.category); setSensitivity(q.sensitivity); }}>Cancel</button></>
          : <button className="ghost" onClick={() => setEditing(true)}>Edit</button>}
        <button className="linkbtn" onClick={() => showLog(q)}>History</button>
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Reports and feedback
// ---------------------------------------------------------------------------

function Reports({ onChanged }) {
  const [status, setStatus] = useState('open');
  const [rows, load, error] = useList('admin_reports', { p_status: status });
  const changed = async () => { await load(); onChanged(); };
  return (
    <>
      <p className="hint">What people reported. A reported friend question shows here so you can check it. Notes are visible to the person who reported it in their data download.</p>
      <Filters value={status} onChange={setStatus} options={[['open', 'Open'], ['actioned', 'Actioned'], ['dismissed', 'Dismissed'], [null, 'All']]} />
      <Err error={error} />
      {rows && rows.length === 0 && <p className="empty">No reports here.</p>}
      <div className="rows">{(rows || []).map(r => <ReportRow key={r.id} r={r} onChanged={changed} />)}</div>
    </>
  );
}

function ReportRow({ r, onChanged }) {
  const [note, setNote] = useState(r.admin_note || '');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  async function set(status, hide) {
    setError(''); setBusy(true);
    try { await call('admin_set_report', { p_report: r.id, p_status: status, p_note: note || null, p_hide_question: !!hide }); await onChanged(); }
    catch (e) { setError(e.message); }
    setBusy(false);
  }
  const q = r.question;
  return (
    <div className="panel">
      <div className="chips">
        <span className="chip">{r.status}</span>
        {q && <span className="chip cat">{q.audience === 'friends' ? 'Friend question' : 'Question'} · {q.status}</span>}
        {r.target && <span className="chip">About @{r.target}</span>}
        {r.reports_on_question > 1 && <span className="chip sensitive">{r.reports_on_question} reports on this question</span>}
      </div>
      {q && <strong>{q.text}</strong>}
      <span>"{r.reason}"</span>
      <span className="hint">From @{r.reporter || 'deleted account'} · {when(r.created_at)}{q && q.by ? ` · question by @${q.by}` : ''}
        {r.handled_at && <><br />{r.status} by {who(r.handled_by)} {when(r.handled_at)}</>}</span>
      <input aria-label="Note" placeholder="Note (optional)" value={note} onChange={e => setNote(e.target.value)}
        style={{ border: '1px solid var(--ink)', padding: '6px 8px', background: 'var(--surface)' }} />
      <Err error={error} />
      <div className="inline" style={{ flexWrap: 'wrap' }}>
        {r.status === 'open' ? <>
          {q && q.status !== 'rejected' && <button className="solid" disabled={busy} onClick={() => set('actioned', true)}>Take question down</button>}
          <button className="ghost" disabled={busy} onClick={() => set('actioned')}>Actioned</button>
          <button className="ghost" disabled={busy} onClick={() => set('dismissed')}>Dismiss</button>
        </> : <button className="ghost" disabled={busy} onClick={() => set('open')}>Reopen</button>}
      </div>
    </div>
  );
}

function Feedback({ onChanged }) {
  const [status, setStatus] = useState('open');
  const [rows, load, error] = useList('admin_feedback', { p_status: status });
  const changed = async () => { await load(); onChanged(); };
  return (
    <>
      <p className="hint">What people sent with the Feedback button, and which screen they were on. Notes are visible to the sender in their data download.</p>
      <Filters value={status} onChange={setStatus} options={[['open', 'Open'], ['done', 'Done'], [null, 'All']]} />
      <Err error={error} />
      {rows && rows.length === 0 && <p className="empty">No feedback here.</p>}
      <div className="rows">{(rows || []).map(f => <FeedbackRow key={f.id} f={f} onChanged={changed} />)}</div>
    </>
  );
}

function FeedbackRow({ f, onChanged }) {
  const [note, setNote] = useState(f.admin_note || '');
  const [error, setError] = useState('');
  async function set(status) {
    setError('');
    try { await call('admin_set_feedback', { p_feedback: f.id, p_status: status, p_note: note || null }); await onChanged(); }
    catch (e) { setError(e.message); }
  }
  return (
    <div className="panel">
      <span style={{ whiteSpace: 'pre-wrap' }}>{f.body}</span>
      <span className="hint">{f.handle ? `@${f.handle} (${f.name})` : 'Deleted account'} · {when(f.created_at)}{f.context ? ` · on ${f.context}` : ''}
        {f.handled_at && <><br />Done by {who(f.handled_by)} {when(f.handled_at)}</>}</span>
      <input aria-label="Note" placeholder="Note (optional)" value={note} onChange={e => setNote(e.target.value)}
        style={{ border: '1px solid var(--ink)', padding: '6px 8px', background: 'var(--surface)' }} />
      <Err error={error} />
      <div className="inline">
        {f.status === 'open'
          ? <button className="solid" onClick={() => set('done')}>Mark done</button>
          : <button className="ghost" onClick={() => set('open')}>Reopen</button>}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// Audit log: every change to a question for everyone, newest first
// ---------------------------------------------------------------------------

const ACTION = { submitted: 'Suggested', approved: 'Approved', rejected: 'Rejected', reopened: 'Back to review', edited: 'Edited', refunded: 'Slashes refunded', daily: 'Daily question' };

function describe(e) {
  if (e.action === 'edited') {
    return Object.keys(e.new_value || {}).map(k => `${k}: "${e.old_value?.[k] ?? ''}" → "${e.new_value[k] ?? ''}"`).join('; ');
  }
  if (e.action === 'refunded') return `${e.new_value?.slashes} slashes`;
  if (e.action === 'daily') return e.new_value?.daily_date ? `Set for ${e.new_value.daily_date}` : `Taken off ${e.old_value?.daily_date ?? 'its day'}`;
  if (e.action === 'submitted') return e.new_value?.category ? `Theme: ${e.new_value.category}` : '';
  return '';
}

function AuditLog({ question, onAll }) {
  const [rows, , error] = useList('admin_audit', { p_question: question ? question.id : null, p_limit: 200 });
  return (
    <>
      {question
        ? <p className="hint">History of "{question.text}" · <button className="linkbtn" onClick={onAll}>Everything</button></p>
        : <p className="hint">Every suggestion, review and edit to questions for everyone. Changes made in the Supabase editors show as SQL Editor.</p>}
      <Err error={error} />
      {rows && rows.length === 0 && <p className="empty">Nothing logged yet.</p>}
      <div className="panel">
        {(rows || []).map(e => (
          <div className="fact" key={e.id}>
            <span className="t"><b>{ACTION[e.action] || e.action}</b> by {who(e.actor)}{!question && (e.new_value?.text && e.action === 'submitted' ? `: ${e.new_value.text}` : e.question ? `: ${e.question}` : '')}</span>
            <span className="m"><span>{when(e.created_at)}</span>{describe(e) && <span>{describe(e)}</span>}{e.note && <span>Note: {e.note}</span>}</span>
          </div>
        ))}
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Daily question: what's on each day, and picking or writing one
// ---------------------------------------------------------------------------

const dayLabel = (date, today) => {
  const diff = Math.round((new Date(date) - new Date(today)) / 864e5);
  const name = new Date(`${date}T12:00:00`).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  return diff === 0 ? `Today · ${name}` : diff === 1 ? `Tomorrow · ${name}` : name;
};

function Daily({ onChanged, themes }) {
  const [info, load, error] = useList('admin_daily', { p_days: 14 });
  const [picking, setPicking] = useState(null);
  const [err, setErr] = useState('');
  const changed = async () => { setPicking(null); await load(); onChanged(); };
  async function clear(date) {
    setErr('');
    try { await call('admin_set_daily', { p_question: null, p_date: date }); await changed(); } catch (e) { setErr(e.message); }
  }
  if (!info) return <Err error={error} />;
  return (
    <>
      <p className="hint">One question for everyone each day, shown first in Today. Empty days are filled from the bank in order ({info.bank_left} unused questions left).
        {!info.timer && ' The hourly timer isn\'t running on this database, so the app fills an empty day when someone opens it. To turn the timer on, enable pg_cron under Database > Extensions in Supabase and run the update again.'}</p>
      <Err error={error || err} />
      <div className="rows">
        {info.days.map(day => {
          const past = day.date < info.today;
          const q = day.question;
          return (
            <div className="panel" key={day.date} style={past ? { opacity: 0.6 } : day.date === info.today ? { background: 'var(--daily)' } : undefined}>
              <span className="label">{dayLabel(day.date, info.today)}</span>
              {q ? <strong>{q.text}</strong> : <span className="hint">{past ? 'No daily question' : 'Empty: the bank fills it the day before'}</span>}
              {q && <span className="hint">{q.category} · {q.answers} answer{q.answers === 1 ? '' : 's'}{q.status !== 'approved' ? ` · ${q.status}, so it will be replaced` : ''}</span>}
              {!past && picking !== day.date && (
                <div className="inline" style={{ flexWrap: 'wrap' }}>
                  <button className="ghost" onClick={() => setPicking(day.date)}>{q ? 'Change' : 'Choose'}</button>
                  {q && day.date !== info.today && <button className="ghost" onClick={() => clear(day.date)}>Clear</button>}
                </div>
              )}
              {picking === day.date && (
                <DailyPicker date={day.date} isToday={day.date === info.today} answered={q ? q.answers : 0}
                  themes={themes} onDone={changed} onCancel={() => setPicking(null)} />
              )}
            </div>
          );
        })}
      </div>
    </>
  );
}

function DailyPicker({ date, isToday, answered, themes, onDone, onCancel }) {
  const [mode, setMode] = useState('pick');
  const [search, setSearch] = useState('');
  const [query, setQuery] = useState('');
  const [rows] = useList('admin_questions', { p_status: 'approved', p_search: query || null, p_limit: 30 });
  const [text, setText] = useState('');
  const [category, setCategory] = useState('General');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const usable = (rows || []).filter(q => !q.is_event && (!q.daily_date || q.daily_date >= date));

  async function use(id) {
    if (isToday && answered > 0
        && !window.confirm(`${answered} people already answered today's question. Swap it anyway? Their answers stay, but it stops being the daily question.`)) return;
    setError(''); setBusy(true);
    try {
      const qid = id ?? await call('admin_create_question', { p_text: text, p_category: category });
      await call('admin_set_daily', { p_question: qid, p_date: date });
      await onDone();
    } catch (e) { setError(e.message); setBusy(false); }
  }
  return (
    <>
      <Filters value={mode} onChange={setMode} options={[['pick', 'Pick from the bank'], ['write', 'Write a new one']]} />
      {mode === 'pick' ? <>
        <form className="inline" onSubmit={e => { e.preventDefault(); setQuery(search.trim()); }}>
          <input type="search" placeholder="Search text or theme" value={search} onChange={e => setSearch(e.target.value)} />
          <button className="ghost">Search</button>
        </form>
        {rows && usable.length === 0 && <p className="empty">No live questions match.</p>}
        {usable.map(q => (
          <div className="toggle-row" key={q.id}>
            <span>{q.text} <span className="hint">· {q.category}{q.daily_date ? ` · set for ${q.daily_date}` : ''}</span></span>
            <button className="ghost" disabled={busy} onClick={() => use(q.id)}>Use</button>
          </div>
        ))}
      </> : (
        <form className="field" onSubmit={e => { e.preventDefault(); use(null); }}>
          <label className="field"><span className="label">Question for everyone</span>
            <input required minLength={5} maxLength={140} value={text} onChange={e => setText(e.target.value)} placeholder="Would you rather..." /></label>
          <select aria-label="Theme" value={category} onChange={e => setCategory(e.target.value)}
            style={{ border: '1px solid var(--ink)', padding: '6px 8px', background: 'var(--surface)' }}>
            {[...new Set([...themes, 'General'])].map(t => <option key={t}>{t}</option>)}
          </select>
          <button className="solid" disabled={busy}>Add it and use it</button>
        </form>
      )}
      <Err error={error} />
      <button className="linkbtn" onClick={onCancel}>Cancel</button>
    </>
  );
}

// ---------------------------------------------------------------------------
// Growth: is yeah/nah spreading? Totals and trends only, never people.
// ---------------------------------------------------------------------------

const RANGES = [[7, '7 days'], [28, '28 days'], [90, '90 days']];
const METRICS = [
  ['answerers', 'Active', n => (n === 1 ? 'person answered' : 'people answered')],
  ['signups', 'Sign-ups', n => (n === 1 ? 'new person' : 'new people'), 'link_signups'],
  ['answers', 'Answers', n => (n === 1 ? 'answer' : 'answers')],
  ['sends', 'Sends', n => (n === 1 ? 'question sent to friends' : 'questions sent to friends'), 'sends_answered'],
  ['link_opens', 'Link opens', n => (n === 1 ? 'question link opened' : 'question links opened')],
];
const pct = (a, b) => (b ? Math.round((100 * a) / b) : null);
const shortDay = d => new Date(`${d}T12:00:00`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short' });

function Growth() {
  const [days, setDays] = useState(28);
  const [g, , error] = useList('admin_growth', { p_days: days });
  if (!g) return <><Filters value={days} onChange={setDays} options={RANGES} /><Err error={error} />{!error && <p className="empty">Counting…</p>}</>;
  const v = g.virality;
  const came = g.came_from;
  const newPeople = came.group + came.link + came.direct;
  return (
    <div className="rows">
      <Filters value={days} onChange={setDays} options={RANGES} />
      <Err error={error} />

      <div className="panel">
        <span className="label">Virality this week</span>
        <div className="vhead">
          <b>{Number(v.v_measured).toFixed(2)}</b>
          <span>1.00 is target pace. Above it, every active person brings in more than the target; below it, the app is spreading slower.</span>
        </div>
        <Spark points={g.virality_trend.map(d => ({ x: d.day, y: Number(d.v) }))} target={1} label="Virality by day" />
        <div className="stats">
          <div className="stat"><b>{Number(v.spread).toFixed(2)}</b><span>spread · target {Number(v.spread_target).toFixed(2)}</span></div>
          <div className="stat"><b>{Number(v.growth).toFixed(2)}</b><span>growth · target {Number(v.growth_target).toFixed(2)}</span></div>
          <div className="stat"><b>{v.weekly_active}</b><span>weekly active</span></div>
        </div>
        <p className="hint">Spread is answered sends per weekly active person; growth is people who joined through a group or question link, per weekly active person. Weekly active means 3+ answers and one in the last 7 days. v weighs spread {Math.round(v.spread_weight * 100)}% and growth the rest.</p>
        {v.v_is_manual && <p className="hint">Fewer than {v.min_people} weekly active people, so slashtax uses the set v of {Number(v.v).toFixed(2)} for now. The measured number above is shown to watch, not to act on.</p>}
      </div>

      <div className="stats">
        <div className="stat"><b>{g.people}</b><span>people</span></div>
        <div className="stat"><b>{g.active.week}</b><span>active this week</span></div>
        <div className="stat"><b>{g.active.today}</b><span>active today</span></div>
      </div>
      <div className="stats">
        <div className="stat"><b>{pct(g.active.today, g.active.month) ?? '–'}{g.active.month ? '%' : ''}</b><span>of the month's people active today</span></div>
        <div className="stat"><b>{g.retention.day1 ?? '–'}{g.retention.day1 != null ? '%' : ''}</b><span>came back the next day</span></div>
        <div className="stat"><b>{g.send_answer_rate ?? '–'}{g.send_answer_rate != null ? '%' : ''}</b><span>sends answered in time</span></div>
      </div>

      <div className="panel">
        <span className="label">This week against last week</span>
        {[['signups', 'Sign-ups'], ['answers', 'Answers'], ['sends', 'Questions sent'], ['link_opens', 'Question links opened']].map(([k, label]) => {
          const [now, before] = g.week[k];
          const change = before ? Math.round((100 * (now - before)) / before) : null;
          return (
            <div className="toggle-row" key={k}>
              <span>{label}</span>
              <span className="num">{now} <span className="hint">{change == null ? (now ? 'new' : '') : change === 0 ? 'same as last week' : `${change > 0 ? '▲' : '▼'} ${Math.abs(change)}% (was ${before})`}</span></span>
            </div>
          );
        })}
      </div>

      <DailyChart rows={g.daily} />

      <div className="panel">
        <span className="label">Where new people came from · last {g.days} days</span>
        {newPeople === 0 ? <p className="hint">Nobody new in this range.</p> : <>
          <Split parts={[['Group invite', came.group, 'fill-solid'], ['Question link', came.link, 'fill-dither'], ['Found it themselves', came.direct, 'fill-open']]} />
          <p className="hint">A join counts as through a link when the person joined a group or opened a question link within an hour of making their profile, the same rule slashtax uses for growth.</p>
        </>}
      </div>

      <div className="panel">
        <span className="label">Still answering, by the week people joined</span>
        <Cohorts rows={g.cohorts} />
        <p className="hint">Week 0 is the week they joined. Each cell is the share of that week's new people who answered anything that week. Blank weeks haven't happened yet.
          {g.retention.week1 != null && ` Of people who joined at least 2 weeks ago, ${g.retention.week1}% answered something in their second week.`}</p>
      </div>

      <div className="panel">
        <span className="label">Friends and privacy</span>
        <div className="stats">
          <div className="stat"><b>{g.friends.avg ?? 0}</b><span>friends per person</span></div>
          <div className="stat"><b>{g.friends.with_any ?? 0}%</b><span>have a friend</span></div>
          <div className="stat"><b>{g.friends.in_groups ?? 0}%</b><span>in a group</span></div>
        </div>
        {g.visibility.public != null && <>
          <span className="hint">Who could see new answers, last {g.days} days</span>
          <Split unit="%" parts={[['Public', g.visibility.public, 'fill-solid'], ['Friends', g.visibility.friends, 'fill-dither'], ['Private', g.visibility.private, 'fill-open']]} />
        </>}
      </div>

      <div className="stats">
        <div className="stat"><b>{g.slashes.minted}</b><span>slashes made this week</span></div>
        <div className="stat"><b>{g.slashes.spent}</b><span>slashes spent this week</span></div>
        <div className="stat"><b>{pct(g.slashes.spent, g.slashes.minted) ?? '–'}{g.slashes.minted ? '%' : ''}</b><span>spent of made</span></div>
      </div>

      <p className="hint">Totals and percentages only: nothing here names or points at a person. Accounts with unlimited slashes are left out, the same as the nightly economy record. Days are UK days; this week means the last 7 days including today.</p>
    </div>
  );
}

// v by day as a line, with the 1.0 target dashed. Tap or hover for a day's number.
function Spark({ points, target, label }) {
  const [at, setAt] = useState(null);
  if (points.length < 2) return null;
  const W = 400, H = 90, pad = 4;
  const max = Math.max(target * 1.25, ...points.map(p => p.y));
  const x = i => pad + (i * (W - 2 * pad)) / (points.length - 1);
  const y = val => H - pad - (val / max) * (H - 2 * pad);
  const d = points.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.y).toFixed(1)}`).join('');
  const shown = at ?? points.length - 1;
  return (
    <figure className="chart" aria-label={label}>
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${label}: ${points.map(p => `${shortDay(p.x)} ${p.y.toFixed(2)}`).join(', ')}`}
        onPointerLeave={() => setAt(null)}>
        <line x1={pad} x2={W - pad} y1={y(target)} y2={y(target)} className="target" />
        <path d={d} className="line" />
        <circle cx={x(shown)} cy={y(points[shown].y)} r="4" className="dot" />
        {points.map((p, i) => (
          <rect key={p.x} x={x(i) - (W / points.length) / 2} y="0" width={W / points.length} height={H} fill="transparent"
            onPointerEnter={() => setAt(i)} onClick={() => setAt(i)} />
        ))}
      </svg>
      <figcaption className="hint">{shortDay(points[shown].x)}: {points[shown].y.toFixed(2)} · dashed line is 1.00</figcaption>
    </figure>
  );
}

function DailyChart({ rows }) {
  const [metric, setMetric] = useState('answerers');
  const [at, setAt] = useState(null);
  const [key, name, unit, partKey] = METRICS.find(m => m[0] === metric);
  const partName = partKey === 'link_signups' ? 'through a link' : 'answered in time';
  const max = Math.max(1, ...rows.map(r => r[key]));
  const shown = rows[at ?? rows.length - 1];
  const total = rows.reduce((n, r) => n + r[key], 0);
  const W = 400, H = 120, gap = rows.length > 40 ? 1 : 2, bw = (W - gap * (rows.length - 1)) / rows.length;
  return (
    <div className="panel">
      <span className="label">Day by day</span>
      <Filters value={metric} onChange={m => { setMetric(m); setAt(null); }} options={METRICS.map(([k, l]) => [k, l])} />
      <figure className="chart">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" onPointerLeave={() => setAt(null)}
          aria-label={`${name} per day: ${rows.map(r => `${shortDay(r.day)} ${r[key]}`).join(', ')}`}>
          <line x1="0" x2={W} y1={H - 0.5} y2={H - 0.5} className="base" />
          {rows.map((r, i) => {
            const h = (r[key] / max) * (H - 4);
            const ph = partKey ? (r[partKey] / max) * (H - 4) : 0;
            const xx = i * (bw + gap);
            return (
              <g key={r.day} onPointerEnter={() => setAt(i)} onClick={() => setAt(i)} className={at === i ? 'on' : ''}>
                <rect x={xx} y="0" width={bw + gap} height={H} fill="transparent" />
                {h > 0 && <rect x={xx} y={H - h} width={bw} height={h} className={partKey ? 'bar open' : 'bar'} />}
                {ph > 0 && <rect x={xx} y={H - ph} width={bw} height={ph} className="bar" />}
              </g>
            );
          })}
        </svg>
        <figcaption className="hint">
          <b>{shortDay(shown.day)}</b>: {shown[key]} {unit(shown[key])}{partKey ? `, ${shown[partKey]} ${partName}` : ''} · {total} over the {rows.length} days, at most {max === 1 && !rows.some(r => r[key]) ? 0 : max} a day
        </figcaption>
        {partKey && <div className="legend hint"><span><i className="sw fill-solid" />{partName}</span><span><i className="sw fill-open" />the rest</span></div>}
      </figure>
    </div>
  );
}

// A 100% bar split into up to three parts, each with its own fill, then the numbers.
function Split({ parts, unit = '' }) {
  const total = parts.reduce((n, p) => n + Number(p[1] || 0), 0) || 1;
  return (
    <>
      <div className="mix" role="img" aria-label={parts.map(([l, n]) => `${l} ${n}${unit}`).join(', ')}>
        {parts.filter(p => p[1] > 0).map(([l, n, fill]) => <i key={l} className={`sw ${fill}`} style={{ flexGrow: n / total }} title={`${l}: ${n}${unit}`} />)}
      </div>
      <div className="legend hint">
        {parts.map(([l, n, fill]) => <span key={l}><i className={`sw ${fill}`} />{l} <b>{n}{unit}</b>{!unit ? ` (${pct(n, total)}%)` : ''}</span>)}
      </div>
    </>
  );
}

function Cohorts({ rows }) {
  if (!rows.length) return <p className="hint">Nobody has joined in the last 8 weeks.</p>;
  return (
    <div className="cohorts" role="table" aria-label="Share of each week's new people still answering">
      <div role="row" className="hint"><span role="columnheader">Joined</span><span role="columnheader">People</span>
        {[0, 1, 2, 3, 4].map(w => <span role="columnheader" key={w}>Wk {w}</span>)}</div>
      {rows.map(r => (
        <div role="row" key={r.week}>
          <span role="cell">{shortDay(r.week)}</span>
          <span role="cell" className="num">{r.size}</span>
          {r.active.map((p, w) => (
            <span role="cell" key={w} className="num cell"
              style={p == null ? undefined : { background: `color-mix(in srgb, var(--yes) ${Math.round(p * 0.45)}%, var(--surface))` }}>
              {p == null ? '' : `${p}%`}
            </span>
          ))}
        </div>
      ))}
    </div>
  );
}
