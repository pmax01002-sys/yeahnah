import React, { useCallback, useEffect, useState } from 'react';
import { call } from './supabase.js';

// ---------------------------------------------------------------------------
// Admin area: only for accounts in public.admins. Every admin_* call is
// checked in the database too, so this screen opening is not the protection.
// ---------------------------------------------------------------------------

const SECTIONS = [['review', 'Review'], ['questions', 'Questions'], ['reports', 'Reports'], ['feedback', 'Feedback'], ['log', 'Audit log']];
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

const ACTION = { submitted: 'Suggested', approved: 'Approved', rejected: 'Rejected', reopened: 'Back to review', edited: 'Edited', refunded: 'Slashes refunded' };

function describe(e) {
  if (e.action === 'edited') {
    return Object.keys(e.new_value || {}).map(k => `${k}: "${e.old_value?.[k] ?? ''}" → "${e.new_value[k] ?? ''}"`).join('; ');
  }
  if (e.action === 'refunded') return `${e.new_value?.slashes} slashes`;
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
