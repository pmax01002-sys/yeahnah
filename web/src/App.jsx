import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, configured, call } from './supabase.js';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const word = (q, v) => (q.option_yes ? (v ? q.option_yes : q.option_no) : v ? 'YEAH' : 'NAH');
const pillClass = (q, v) => (q.option_yes ? (v ? 'oa' : 'ob') : v ? 'yes' : 'no');
const Pill = ({ q, v }) => <span className={`vpill ${pillClass(q, v)}`}>{word(q, v).toUpperCase()}</span>;
const SENS = { standard: 'Standard', personal: 'Personal', sensitive: 'Sensitive' };
const TIMERS = [[1, '1 min'], [60, '1 hour'], [1440, '1 day']];
const todayUK = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/London' });

function useNow(ms) {
  const [now, setNow] = useState(Date.now());
  useEffect(() => { const t = setInterval(() => setNow(Date.now()), ms); return () => clearInterval(t); }, [ms]);
  return now;
}
function left(expires, now) {
  const s = Math.max(0, Math.round((new Date(expires) - now) / 1000));
  if (s >= 3600) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`;
  if (s >= 60) return `${Math.floor(s / 60)}m ${s % 60}s`;
  return `${s}s`;
}
function Chips({ q, children }) {
  return (
    <div className="chips">
      <span className="chip cat">{q.category}</span>
      <span className={`chip ${q.sensitivity}`}>{SENS[q.sensitivity]}</span>
      {q.partner && <span className="chip cat">{q.partner} can verify</span>}
      {children}
    </div>
  );
}
function Msg({ error, note }) {
  if (error) return <div className="error" role="alert">{error}</div>;
  if (note) return <div className="note" role="status">{note}</div>;
  return null;
}

// ---------------------------------------------------------------------------
// App shell: setup check, sign in, profile, then the five tabs
// ---------------------------------------------------------------------------

export default function App() {
  const [session, setSession] = useState(undefined);

  useEffect(() => {
    if (!configured) return;
    supabase.auth.getSession().then(({ data }) => setSession(data.session));
    const { data } = supabase.auth.onAuthStateChange((_e, s) => setSession(s));
    return () => data.subscription.unsubscribe();
  }, []);

  if (!configured) {
    return (
      <div className="app"><div className="screen center">
        <div className="big-brand"><span>yeah</span>/<em>nah</em></div>
        <p>This copy isn't connected to a database yet. Set <code>VITE_SUPABASE_URL</code> and{' '}
          <code>VITE_SUPABASE_ANON_KEY</code> (see the README) and rebuild.</p>
      </div></div>
    );
  }
  if (session === undefined) return <div className="app" />;
  if (!session) return <SignIn />;
  return <Signed key={session.user.id} />;
}

function SignIn() {
  const [mode, setMode] = useState('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true); setError(''); setNote('');
    const fn = mode === 'signin' ? 'signInWithPassword' : 'signUp';
    const { data, error } = await supabase.auth[fn]({ email, password });
    setBusy(false);
    if (error) return setError(error.message);
    if (mode === 'signup' && !data.session) setNote('Check your email to confirm, then sign in.');
  }

  return (
    <div className="app"><form className="screen center" onSubmit={submit}>
      <div className="big-brand"><span>yeah</span>/<em>nah</em></div>
      <p className="hint">One yes/no question a day. Your answers build your profile.</p>
      <div className="seg" role="group" aria-label="Sign in or sign up">
        <button type="button" aria-pressed={mode === 'signin'} onClick={() => setMode('signin')}>Sign in</button>
        <button type="button" aria-pressed={mode === 'signup'} onClick={() => setMode('signup')}>New here</button>
      </div>
      <label className="field"><span className="label">Email</span>
        <input type="email" required autoComplete="email" value={email} onChange={e => setEmail(e.target.value)} /></label>
      <label className="field"><span className="label">Password</span>
        <input type="password" required minLength={8} autoComplete={mode === 'signin' ? 'current-password' : 'new-password'}
          value={password} onChange={e => setPassword(e.target.value)} /></label>
      <Msg error={error} note={note} />
      <button className="solid" disabled={busy}>{mode === 'signin' ? 'Sign in' : 'Create account'}</button>
      <p className="hint">Demo build. Credits are free play credits with no money value.</p>
    </form></div>
  );
}

function CreateProfile({ onDone }) {
  const [f, setF] = useState({ handle: '', name: '', birth: '' });
  const [error, setError] = useState('');
  async function submit(e) {
    e.preventDefault(); setError('');
    try {
      await call('create_profile', { p_handle: f.handle, p_display_name: f.name, p_birth_date: f.birth });
      onDone();
    } catch (err) { setError(err.message); }
  }
  const set = k => e => setF({ ...f, [k]: e.target.value });
  return (
    <div className="app"><form className="screen center" onSubmit={submit}>
      <h1>Make your profile</h1>
      <label className="field"><span className="label">Handle</span>
        <input required pattern="[A-Za-z0-9_]{3,20}" placeholder="max_01" value={f.handle} onChange={set('handle')} /></label>
      <label className="field"><span className="label">Name people see</span>
        <input required maxLength={40} value={f.name} onChange={set('name')} /></label>
      <label className="field"><span className="label">Date of birth</span>
        <input type="date" required value={f.birth} onChange={set('birth')} /></label>
      <p className="hint">You must be 13 or over. Under-18s get a friends-only profile and no sensitive questions. Your date of birth is never shown to anyone.</p>
      <Msg error={error} />
      <button className="solid">Start answering</button>
    </form></div>
  );
}

// Everything a signed-in screen needs, reloaded after every action.
function useData() {
  const [d, setD] = useState(null);
  const reload = useCallback(async () => {
    const me = await call('my_profile');
    if (!me) return setD({ me: null });
    const [questions, mine, follows, challenges, predictions] = await Promise.all([
      supabase.from('questions').select('*').order('id'),
      supabase.from('statements').select('*').eq('user_id', me.id).is('superseded_at', null),
      supabase.from('follows').select('follower,followed'),
      supabase.from('challenges').select('*').order('created_at', { ascending: false }),
      supabase.from('predictions').select('*').order('created_at', { ascending: false }),
    ]);
    const ids = new Set();
    follows.data.forEach(f => { ids.add(f.follower); ids.add(f.followed); });
    challenges.data.forEach(c => { ids.add(c.from_user); ids.add(c.to_user); });
    predictions.data.forEach(p => p.target_user && ids.add(p.target_user));
    const { data: people } = ids.size
      ? await supabase.from('profiles').select('id,handle,display_name').in('id', [...ids])
      : { data: [] };
    const person = Object.fromEntries(people.map(p => [p.id, p]));
    const iFollow = new Set(follows.data.filter(f => f.follower === me.id).map(f => f.followed));
    const followsMe = new Set(follows.data.filter(f => f.followed === me.id).map(f => f.follower));
    setD({
      me,
      questions: questions.data,
      byId: Object.fromEntries(questions.data.map(q => [q.id, q])),
      mine: Object.fromEntries(mine.data.map(s => [s.question_id, s])),
      person, iFollow, followsMe,
      friends: [...iFollow].filter(id => followsMe.has(id)).map(id => person[id]),
      challenges: challenges.data,
      predictions: predictions.data,
    });
  }, []);
  useEffect(() => { reload(); }, [reload]);
  return [d, reload];
}

function Signed() {
  const [d, reload] = useData();
  const [tab, setTab] = useState('today');
  const [sheet, setSheet] = useState(null);
  const now = useNow(1000);

  if (!d) return <div className="app" />;
  if (!d.me) return <CreateProfile onDone={reload} />;

  const inbox = d.challenges.filter(c => c.to_user === d.me.id && !c.answered_at && new Date(c.expires_at) > now);
  const ctx = { d, reload, open: setSheet, now, inbox };
  const TABS = [['today', '☀️', 'Today'], ['questions', '📋', 'Questions'], ['predict', '🔮', 'Predict'], ['friends', '👥', 'Friends'], ['profile', '🙂', 'Profile']];

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand"><span>yeah</span>/<em>nah</em></div>
        <div className="pills">
          <span className="pill" title="Answers left today">{d.me.answers_left_today} left</span>
          <span className="pill credits" title="Free play credits">{d.me.credits} cr</span>
        </div>
      </header>
      <main className="screen" key={tab}>
        {tab === 'today' && <Today {...ctx} />}
        {tab === 'questions' && <Questions {...ctx} />}
        {tab === 'predict' && <Predict {...ctx} />}
        {tab === 'friends' && <Friends {...ctx} />}
        {tab === 'profile' && <Profile {...ctx} />}
      </main>
      <nav className="nav" aria-label="Main">
        {TABS.map(([k, ico, label]) => (
          <button key={k} aria-current={tab === k ? 'page' : 'false'} onClick={() => { setTab(k); setSheet(null); }}>
            <span className="ico" aria-hidden="true">{ico}</span>{label}
            {k === 'friends' && inbox.length > 0 && <span className="badge">{inbox.length}</span>}
          </button>
        ))}
      </nav>
      {sheet && (
        <div className="scrim" onClick={e => e.target === e.currentTarget && setSheet(null)}>
          <div className="sheet" role="dialog" aria-modal="true">
            <div className="sheet-top"><button className="close" onClick={() => setSheet(null)}>Close</button></div>
            <QuestionCard q={d.byId[sheet]} small {...ctx} />
          </div>
        </div>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// The question card: answer, see the split, set who sees it, send to a friend
// ---------------------------------------------------------------------------

function QuestionCard({ q, small, d, reload, now, inbox }) {
  const mine = d.mine[q.id];
  const [split, setSplit] = useState(null);
  const [friendAns, setFriendAns] = useState([]);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [sendTo, setSendTo] = useState('');
  const [timer, setTimer] = useState(1440);
  const challenge = inbox.find(c => c.question_id === q.id);

  useEffect(() => {
    setError(''); setNote('');
    if (!mine) { setSplit(null); setFriendAns([]); return; }
    call('question_split', { p_question: q.id }).then(setSplit).catch(() => {});
    call('friends_answers', { p_question: q.id }).then(setFriendAns).catch(() => {});
  }, [q.id, mine?.id]);

  async function act(fn, args, done) {
    setError(''); setNote('');
    try { await call(fn, args); if (done) setNote(done); await reload(); } catch (e) { setError(e.message); }
  }

  let body;
  if (q.sensitivity === 'sensitive' && !d.me.sensitive_opt_in) {
    body = (
      <div className="lock">
        <strong>Sensitive question</strong>
        <p className="hint">Reveals religious or political views. Needs your opt-in, starts private and is never used for brands.</p>
        <button className="solid" onClick={() => act('set_sensitive_opt_in', { p_on: true })}>Turn on sensitive questions</button>
      </div>
    );
  } else if (!mine) {
    const opts = q.option_yes
      ? [[true, q.emoji_yes, q.option_yes], [false, q.emoji_no, q.option_no]]
      : [[true, null, 'Yeah'], [false, null, 'Nah']];
    body = (
      <>
        <div className="answer-row">
          {opts.map(([v, emoji, label]) => (
            <button key={label} className={`big ${q.option_yes ? 'pick' : v ? 'yes' : 'no'}`}
              onClick={() => act('answer', { p_question: q.id, p_value: v })}>
              {emoji && <span className="e" aria-hidden="true">{emoji}</span>}{label}
            </button>
          ))}
        </div>
        <p className="hint">You see how everyone answered after you vote.</p>
      </>
    );
  } else {
    const pct = split && split.total ? Math.round((100 * split.yes) / split.total) : 0;
    const hidden = mine.hidden_until && new Date(mine.hidden_until) > now;
    const canSend = q.sensitivity !== 'sensitive' && d.friends.length > 0;
    body = (
      <>
        <div className="inline">
          <span>{mine.source === 'app' ? 'You said' : `${mine.source} says`}</span><Pill q={q} v={mine.value} />
          {mine.verified && <span className="chip personal">verified</span>}
        </div>
        {split && (
          <>
            <div className={`split${q.option_yes ? ' pick' : ''}`} role="img" aria-label={`${pct}% ${word(q, true)}, ${100 - pct}% ${word(q, false)}`}>
              <div className="y" style={{ width: `${pct}%` }}>{pct}% {q.option_yes ? q.emoji_yes : 'yeah'}</div>
              <div className="n">{100 - pct}% {q.option_yes ? q.emoji_no : 'nah'}</div>
            </div>
            <div className="meta">
              <span>{split.total} answer{split.total === 1 ? '' : 's'} so far</span>
              {friendAns.map(f => <span key={f.handle}>{f.display_name}: {word(q, f.value)}</span>)}
            </div>
          </>
        )}
        {q.daily_date === todayUK() && split && pct < 50 && mine.value && split.total > 1 &&
          <div className="hook">You're one of the {pct}% who said yeah.</div>}
        <span className="label">Who sees this answer on your profile</span>
        <div className="seg" role="group" aria-label="Visibility">
          {['public', 'friends', 'private'].filter(v => d.me.is_adult || v !== 'public').map(v => (
            <button key={v} aria-pressed={mine.visibility === v}
              onClick={() => act('set_visibility', { p_question: q.id, p_visibility: v })}>{v[0].toUpperCase() + v.slice(1)}</button>
          ))}
        </div>
        {hidden && <p className="hint">You changed your mind, so this stays hidden from others until {new Date(mine.hidden_until).toLocaleDateString('en-GB')}.</p>}
        {!mine.verified && (d.me.changes_left_today > 0
          ? <button className="linkbtn" onClick={() => act('answer', { p_question: q.id, p_value: !mine.value }, 'Changed. That was today\'s change of mind.')}>
              Change my answer to {word(q, !mine.value).toLowerCase()} (1 a day)</button>
          : <p className="hint">You've used today's change of mind.</p>)}
        {canSend && (
          <div className="panel">
            <span className="label">Send to a friend (3 credits). They get 2 if they answer in time.</span>
            <div className="inline">
              <select value={sendTo} onChange={e => setSendTo(e.target.value)} aria-label="Friend">
                <option value="">Pick a friend</option>
                {d.friends.map(f => <option key={f.id} value={f.handle}>{f.display_name} (@{f.handle})</option>)}
              </select>
            </div>
            <div className="seg" role="group" aria-label="Timer">
              {TIMERS.map(([m, l]) => <button key={m} aria-pressed={timer === m} onClick={() => setTimer(m)}>{l}</button>)}
            </div>
            <button className="ghost" disabled={!sendTo}
              onClick={() => act('send_challenge', { p_handle: sendTo, p_question: q.id, p_minutes: timer }, 'Sent. The clock is ticking.')}>Send</button>
          </div>
        )}
      </>
    );
  }

  return (
    <div className={`card${small ? ' small' : ''}`}>
      <Chips q={q}>{challenge && <span className="chip timer">⏱ {left(challenge.expires_at, now)}</span>}</Chips>
      <h2 className="qtext">{q.text}</h2>
      {challenge && !mine && <p className="hint">Sent by {d.person[challenge.from_user]?.display_name}. Answer before the timer runs out for 2 credits. Doesn't count towards your daily answers.</p>}
      {body}
      <Msg error={error} note={note} />
    </div>
  );
}

function Row({ q, d, open, extra }) {
  const mine = d.mine[q.id];
  const locked = q.sensitivity === 'sensitive' && !d.me.sensitive_opt_in;
  return (
    <button className="row" onClick={() => open(q.id)}>
      <span><span className="t">{q.text}</span><Chips q={q}>{extra}</Chips></span>
      <span>{locked ? '🔒' : mine ? <Pill q={q} v={mine.value} /> : null}</span>
    </button>
  );
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function Today(ctx) {
  const { d, inbox, now } = ctx;
  const daily = d.questions.find(q => q.daily_date === todayUK());
  const next = d.questions.filter(q => !q.is_event && !q.daily_date && !d.mine[q.id] && q.sensitivity !== 'sensitive').slice(0, 4);
  const date = new Date().toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Europe/London' });
  return (
    <>
      <div className="head"><span className="eyebrow">{date} · Today's question</span></div>
      {daily ? <QuestionCard q={daily} {...ctx} /> : <p className="empty">No question today yet.</p>}
      {inbox.length > 0 && (
        <div className="section"><h2>Sent to you</h2>
          <div className="rows">{inbox.map(c => (
            <Row key={c.id} q={d.byId[c.question_id]} {...ctx}
              extra={<span className="chip timer">⏱ {left(c.expires_at, now)} · {d.person[c.from_user]?.display_name}</span>} />
          ))}</div>
        </div>
      )}
      <div className="section"><h2>Keep going</h2>
        <p className="hint">
          {d.me.other_answers_left_today > 0
            ? `${d.me.other_answers_left_today} more answer${d.me.other_answers_left_today === 1 ? '' : 's'} today, with one always kept for the daily question.`
            : 'That\'s your answers for today. Questions friends send you still count.'}
        </p>
        <div className="rows">{next.map(q => <Row key={q.id} q={q} {...ctx} />)}</div>
      </div>
    </>
  );
}

function Questions(ctx) {
  const { d, inbox } = ctx;
  const [filter, setFilter] = useState('all');
  const sent = new Set(inbox.map(c => c.question_id));
  const F = { all: 'All', open: 'Not answered', sent: 'Sent to you', standard: 'Standard', personal: 'Personal', sensitive: 'Sensitive' };
  const qs = d.questions.filter(q => !q.is_event && q.status === 'approved');
  const list = qs.filter(q => filter === 'all' || (filter === 'open' ? !d.mine[q.id] : filter === 'sent' ? sent.has(q.id) : q.sensitivity === filter));
  return (
    <>
      <div className="filters" role="group" aria-label="Filter">
        {Object.entries(F).map(([k, v]) => <button key={k} aria-pressed={filter === k} onClick={() => setFilter(k)}>{v}</button>)}
      </div>
      <p className="hint" style={{ margin: '4px 2px 10px' }}>{Object.keys(d.mine).length} answered · showing {list.length}</p>
      <div className="rows">{list.map(q => <Row key={q.id} q={q} {...ctx} />)}</div>
      <SuggestQuestion />
    </>
  );
}

function SuggestQuestion() {
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  async function submit(e) {
    e.preventDefault(); setError(''); setNote('');
    try { await call('submit_question', { p_text: text }); setText(''); setNote('Thanks. A moderator checks it before it goes live.'); }
    catch (err) { setError(err.message); }
  }
  return (
    <form className="section" onSubmit={submit}><h2>Suggest a question</h2>
      <div className="inline"><input required minLength={5} maxLength={140} placeholder="Is cereal a soup?" value={text} onChange={e => setText(e.target.value)} />
        <button className="ghost">Send</button></div>
      <Msg error={error} note={note} />
    </form>
  );
}

function Predict({ d, reload }) {
  const [error, setError] = useState('');
  const [friend, setFriend] = useState(d.friends[0]?.handle || '');
  const [friendAnswered, setFriendAnswered] = useState(new Set());
  const daily = d.questions.find(q => q.daily_date === todayUK());
  const events = d.questions.filter(q => q.is_event);
  const mineP = (kind, qid, target) => d.predictions.find(p => p.kind === kind && p.question_id === qid && (p.target_user || null) === (target || null));
  const friendId = d.friends.find(f => f.handle === friend)?.id;
  const hr = d.me.predictions;

  useEffect(() => {
    if (!friendId) return;
    supabase.from('statements').select('question_id').eq('user_id', friendId)
      .then(({ data }) => setFriendAnswered(new Set((data || []).map(s => s.question_id))));
  }, [friendId]);

  async function guess(kind, q, yes) {
    setError('');
    try { await call('predict', { p_kind: kind, p_question: q.id, p_yes: yes, p_friend: kind === 'friend' ? friend : null }); await reload(); }
    catch (e) { setError(e.message); }
  }
  const status = p => !p.resolved_at ? 'waiting' : p.correct === null ? 'void' : p.correct ? 'right ✓' : 'wrong ✗';
  const Guess = ({ kind, q, target }) => {
    const p = mineP(kind, q.id, target);
    if (p) return <span className="hint">You said <Pill q={q} v={p.predicts_yes} /> · {status(p)}</span>;
    return (
      <div className="answer-row">
        <button className="ghost" onClick={() => guess(kind, q, true)}>{q.option_yes || 'Yeah'}</button>
        <button className="ghost" onClick={() => guess(kind, q, false)}>{q.option_no || 'Nah'}</button>
      </div>
    );
  };
  const friendQs = friendId
    ? d.questions.filter(q => !q.is_event && q.sensitivity !== 'sensitive' && !friendAnswered.has(q.id) && !mineP('friend', q.id, friendId)).slice(0, 5)
    : [];

  return (
    <>
      <div className="stats">
        <div className="stat"><b>{hr.rate ?? '–'}{hr.rate != null && '%'}</b><span>hit rate</span></div>
        <div className="stat"><b>{hr.correct}/{hr.resolved}</b><span>right</span></div>
        <div className="stat"><b>{hr.made}</b><span>guesses</span></div>
      </div>
      <p className="hint" style={{ marginTop: 8 }}>Guesses are free. Your hit rate shows on your profile.</p>
      <Msg error={error} />

      {daily && (
        <div className="section"><h2>The crowd</h2>
          <div className="panel"><strong>How will everyone answer "{daily.text}" by midnight?</strong>
            <Guess kind="crowd" q={daily} /></div>
        </div>
      )}

      <div className="section"><h2>Your friends</h2>
        {d.friends.length === 0 ? <p className="empty">Add friends to guess their answers.</p> : (
          <>
            <select className="ghost" value={friend} onChange={e => setFriend(e.target.value)} aria-label="Friend">
              {d.friends.map(f => <option key={f.id} value={f.handle}>{f.display_name}</option>)}
            </select>
            {friendQs.map(q => (
              <div className="panel" key={q.id}><strong>{q.text}</strong><Guess kind="friend" q={q} target={friendId} /></div>
            ))}
            {d.predictions.filter(p => p.kind === 'friend').slice(0, 10).map(p => (
              <p className="hint" key={p.id}>{d.person[p.target_user]?.display_name} · {d.byId[p.question_id]?.text} · you said {p.predicts_yes ? 'yeah' : 'nah'} · {status(p)}</p>
            ))}
          </>
        )}
      </div>

      <div className="section"><h2>World events</h2>
        {events.map(q => (
          <div className="panel" key={q.id}>
            <strong>{q.text}</strong>
            {q.outcome !== null
              ? <span className="hint">Settled: <Pill q={q} v={q.outcome} /> {mineP('event', q.id) && `· you were ${status(mineP('event', q.id))}`}</span>
              : <><span className="hint">Closes {new Date(q.closes_at).toLocaleDateString('en-GB')}</span><Guess kind="event" q={q} /></>}
          </div>
        ))}
      </div>
    </>
  );
}

function Friends({ d, reload, open, now, inbox }) {
  const [handle, setHandle] = useState('');
  const [card, setCard] = useState(null);
  const [error, setError] = useState('');
  const [agree, setAgree] = useState({});
  const meId = d.me.id;

  useEffect(() => {
    d.friends.forEach(f => call('agreement_with', { p_handle: f.handle }).then(a => setAgree(x => ({ ...x, [f.id]: a }))).catch(() => {}));
  }, [d.friends.length]);

  async function find(e) {
    e.preventDefault(); setError(''); setCard(null);
    const c = await call('profile_card', { p_handle: handle.replace(/^@/, '') }).catch(err => setError(err.message));
    if (c === null) setError('No one with that handle');
    else if (c) setCard(c);
  }
  async function follow(id, on) {
    setError('');
    const { error } = on
      ? await supabase.from('follows').insert({ follower: meId, followed: id })
      : await supabase.from('follows').delete().eq('follower', meId).eq('followed', id);
    if (error) setError(error.message);
    await reload();
    if (card) setCard(await call('profile_card', { p_handle: card.handle }));
  }
  const requests = [...d.followsMe].filter(id => !d.iFollow.has(id)).map(id => d.person[id]);
  const waiting = [...d.iFollow].filter(id => !d.followsMe.has(id)).map(id => d.person[id]);
  const cardId = card && Object.values(d.person).find(p => p.handle === card.handle)?.id;

  return (
    <>
      <form className="inline" onSubmit={find} style={{ marginTop: 6 }}>
        <input placeholder="Find someone by @handle" value={handle} onChange={e => setHandle(e.target.value)} aria-label="Handle" />
        <button className="ghost">Find</button>
      </form>
      <Msg error={error} />
      {card && card.handle !== d.me.handle && (
        <div className="panel" style={{ marginTop: 10 }}>
          <strong>{card.display_name} <span className="hint">@{card.handle}</span></strong>
          <span className="hint">Hit rate {card.predictions.rate ?? '–'}{card.predictions.rate != null && '%'} · {card.is_friend ? 'Friends' : card.follows_me ? 'Follows you' : 'Not connected'}</span>
          {card.i_follow
            ? <button className="ghost" onClick={() => follow(cardId, false)}>Unfollow</button>
            : <button className="solid" onClick={async () => {
                const { data } = await supabase.from('profiles').select('id').eq('handle', card.handle).single();
                follow(data.id, true);
              }}>{card.follows_me ? 'Follow back' : 'Follow'}</button>}
        </div>
      )}

      {inbox.length > 0 && (
        <div className="section"><h2>Sent to you</h2>
          {inbox.map(c => (
            <button key={c.id} className="row" onClick={() => open(c.question_id)}>
              <span><span className="t">{d.byId[c.question_id]?.text}</span><span className="hint">from {d.person[c.from_user]?.display_name}</span></span>
              <span className="chip timer">⏱ {left(c.expires_at, now)}</span>
            </button>
          ))}
        </div>
      )}

      {requests.length > 0 && (
        <div className="section"><h2>Want to be friends</h2>
          {requests.map(p => (
            <div className="panel" key={p.id}><div className="toggle-row"><span>{p.display_name} <span className="hint">@{p.handle}</span></span>
              <button className="solid" onClick={() => follow(p.id, true)}>Follow back</button></div></div>
          ))}
        </div>
      )}

      <div className="section"><h2>Friends</h2>
        <p className="hint">Friends follow each other. Only friends can send you questions or see friends-only answers.</p>
        {d.friends.length === 0 && <p className="empty">No friends yet. Find someone by their handle.</p>}
        {d.friends.map(f => {
          const a = agree[f.id];
          return (
            <div className="panel" key={f.id}><div className="toggle-row">
              <span>{f.display_name} <span className="hint">@{f.handle}</span></span>
              <span className="agree">{a && a.both > 0 ? <><b>{Math.round((100 * a.agree) / a.both)}%</b> <span className="hint">agree on {a.both}</span></> : <span className="hint">nothing in common yet</span>}</span>
            </div></div>
          );
        })}
        {waiting.map(p => <p className="hint" key={p.id}>Waiting for {p.display_name} to follow back.</p>)}
      </div>
      <SentByMe d={d} now={now} />
    </>
  );
}

function SentByMe({ d, now }) {
  const sent = d.challenges.filter(c => c.from_user === d.me.id).slice(0, 10);
  if (!sent.length) return null;
  return (
    <div className="section"><h2>You sent</h2>
      {sent.map(c => (
        <p className="hint" key={c.id}>{d.person[c.to_user]?.display_name} · {d.byId[c.question_id]?.text} · {
          c.answered_at ? 'answered in time' : new Date(c.expires_at) > now ? `⏱ ${left(c.expires_at, now)}` : 'ran out of time'}</p>
      ))}
    </div>
  );
}

function Profile({ d, reload }) {
  const [error, setError] = useState('');
  const facts = Object.values(d.mine).map(s => ({ s, q: d.byId[s.question_id] })).filter(x => x.q)
    .sort((a, b) => a.q.category.localeCompare(b.q.category) || a.q.id - b.q.id);
  const yn = facts.filter(x => !x.q.option_yes);
  const yesPct = yn.length ? Math.round((100 * yn.filter(x => x.s.value).length) / yn.length) : 0;
  const hr = d.me.predictions;

  async function act(fn, args) {
    setError('');
    try { await call(fn, args); await reload(); } catch (e) { setError(e.message); }
  }
  async function download() {
    const data = await call('export_my_data');
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
    a.download = `yeahnah-${d.me.handle}.json`;
    a.click();
  }
  async function del() {
    if (!window.confirm('Delete your account and every answer? This cannot be undone.')) return;
    await act('delete_my_account');
    await supabase.auth.signOut();
  }

  return (
    <>
      <div className="head" style={{ display: 'block' }}>
        <h1>{d.me.display_name}</h1>
        <span className="hint">@{d.me.handle} · {d.me.is_adult ? '18+' : 'Under 18: friends-only profile'}</span>
      </div>
      <div className="stats">
        <div className="stat"><b>{facts.length}</b><span>answers</span></div>
        <div className="stat"><b>{yesPct}%</b><span>said yeah</span></div>
        <div className="stat"><b>{hr.rate ?? '–'}{hr.rate != null && '%'}</b><span>hit rate</span></div>
      </div>
      <Msg error={error} />

      <div className="section"><h2>Your yes/no profile</h2>
        <div className="panel">
          {facts.length === 0 && <p className="empty">Answer today's question to start your profile.</p>}
          {facts.map(({ s, q }) => (
            <div className="fact" key={s.id}>
              <span className="t">{q.text}</span><Pill q={q} v={s.value} />
              <span className="m"><span className={`chip ${q.sensitivity}`}>{SENS[q.sensitivity]}</span>
                <span>Source: {s.verified ? `${s.source}, verified` : 'you'}</span><span>Visible to: {s.visibility}</span>
                {q.option_yes && <span>Stored as: {q.option_yes} over {q.option_no} = {s.value ? 'YES' : 'NO'}</span>}</span>
            </div>
          ))}
        </div>
      </div>

      {d.me.is_adult && (
        <div className="section"><h2>Sensitive questions</h2>
          <div className="panel"><div className="toggle-row"><strong>Answer religious and political questions</strong>
            <button className="switch" role="switch" aria-checked={d.me.sensitive_opt_in} aria-label="Sensitive questions"
              onClick={() => act('set_sensitive_opt_in', { p_on: !d.me.sensitive_opt_in })} /></div>
            <p className="hint">{d.me.sensitive_opt_in
              ? 'On. These answers start private and never count towards brand data. Turning this off makes them all private.'
              : 'Off. We record when you agree so you can withdraw at any time.'}</p></div>
        </div>
      )}

      <div className="section"><h2>Your data</h2>
        <div className="panel">
          <p className="hint">We never sell your answers. Brands only ever see totals for groups of 100+ people.</p>
          <button className="ghost" onClick={download}>Download my data</button>
          <button className="ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
          <button className="ghost danger" onClick={del}>Delete my account</button>
        </div>
      </div>
    </>
  );
}
