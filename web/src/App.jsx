import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, configured, call } from './supabase.js';
import { Px } from './icons.jsx';
import { useDeckMotion } from './deckMotion.js';

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

const word = (q, v) => (q.option_yes ? (v ? q.option_yes : q.option_no) : v ? 'YEAH' : 'NAH');
const pillClass = (q, v) => (q.option_yes ? (v ? 'oa' : 'ob') : v ? 'yes' : 'no');
const Pill = ({ q, v }) => <span className={`vpill ${pillClass(q, v)}`}>{word(q, v).toUpperCase()}</span>;
const SENS = { standard: 'Standard', personal: 'Personal', sensitive: 'Sensitive' };
const TIMERS = [[1, '1 min'], [60, '1 hour'], [1440, '1 day']];
const todayUK = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Europe/London' });

// An invite link (?join=CODE) is remembered until the person has a profile,
// so it survives signing up. Storage can be blocked, so keep a copy in memory.
const JOIN_KEY = 'yeahnah-join';
let inviteCode = null;
function pendingInvite() {
  const fromUrl = new URLSearchParams(window.location.search).get('join');
  if (fromUrl) {
    inviteCode = fromUrl;
    try { localStorage.setItem(JOIN_KEY, fromUrl); } catch { /* memory copy is enough */ }
    window.history.replaceState(null, '', window.location.pathname);
  }
  if (!inviteCode) try { inviteCode = localStorage.getItem(JOIN_KEY); } catch { /* none */ }
  return inviteCode;
}
function clearInvite() {
  inviteCode = null;
  try { localStorage.removeItem(JOIN_KEY); } catch { /* none */ }
}
pendingInvite();

// A question link (?q=CODE) is remembered the same way.
const QUESTION_KEY = 'yeahnah-q';
let questionCode = null;
function pendingQuestion() {
  const fromUrl = new URLSearchParams(window.location.search).get('q');
  if (fromUrl) {
    questionCode = fromUrl;
    try { localStorage.setItem(QUESTION_KEY, fromUrl); } catch { /* memory copy is enough */ }
    window.history.replaceState(null, '', window.location.pathname);
  }
  if (!questionCode) try { questionCode = localStorage.getItem(QUESTION_KEY); } catch { /* none */ }
  return questionCode;
}
function clearQuestion() {
  questionCode = null;
  try { localStorage.removeItem(QUESTION_KEY); } catch { /* none */ }
}
pendingQuestion();

// The question from a link, shown on the sign-up page.
function QuestionBanner() {
  const [q, setQ] = useState(null);
  useEffect(() => {
    const code = pendingQuestion();
    if (code) call('question_preview', { p_code: code }).then(setQ).catch(() => {});
  }, []);
  if (!q) return null;
  return (
    <div className="card shared-q">
      <span className="label">{q.by ? `${q.by} asked you` : 'You were asked'}</span>
      <h2 className="qtext">{q.text}</h2>
      <p className="hint">{q.live
        ? 'Sign up to answer it and see how everyone else answered.'
        : 'It goes live once a moderator approves it, and this link works then.'}</p>
    </div>
  );
}

function InviteBanner() {
  const [g, setG] = useState(null);
  useEffect(() => {
    const code = pendingInvite();
    if (code) call('group_preview', { p_code: code }).then(setG).catch(() => {});
  }, []);
  if (!g) return null;
  return (
    <div className="hook">
      {g.invited_by ? `${g.invited_by} invited you` : 'You\'re invited'} to join <b>{g.name}</b>
      {g.members > 1 && ` with ${g.members - 1} other${g.members === 2 ? '' : 's'}`}. Sign up and you'll see how each other answered.
    </div>
  );
}

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
  const [mode, setMode] = useState(pendingInvite() || pendingQuestion() ? 'signup' : 'signin');
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
      <p className="slogan">Believe it? Call it!</p>
      <p className="hint">One yes/no question a day. Your answers build your profile.</p>
      <InviteBanner />
      <QuestionBanner />
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
      <p className="hint">A test version for friends. <PrivacyLink>How we handle your data</PrivacyLink></p>
    </form></div>
  );
}

const PrivacyLink = ({ children }) => <a href="/privacy.html" target="_blank" rel="noopener">{children}</a>;

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
      <InviteBanner />
      <label className="field"><span className="label">Handle</span>
        <input required pattern="[A-Za-z0-9_]{3,20}" placeholder="max_01" value={f.handle} onChange={set('handle')} /></label>
      <label className="field"><span className="label">Name people see</span>
        <input required maxLength={40} value={f.name} onChange={set('name')} /></label>
      <label className="field"><span className="label">Date of birth</span>
        <input type="date" required value={f.birth} onChange={set('birth')} /></label>
      <p className="hint">Your date of birth is never shown to anyone. <PrivacyLink>Privacy notice</PrivacyLink></p>
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
    const [questions, mine, follows, challenges, predictions, groups, members, config, stars, unlock, powerup] = await Promise.all([
      supabase.from('questions').select('*').order('id'),
      supabase.from('statements').select('*').eq('user_id', me.id).is('superseded_at', null),
      supabase.from('follows').select('follower,followed'),
      supabase.from('challenges').select('*').order('created_at', { ascending: false }),
      supabase.from('predictions').select('*').order('created_at', { ascending: false }),
      supabase.from('groups').select('id,name,invite_code,created_by').order('created_at'),
      supabase.from('group_members').select('group_id,user_id').order('joined_at'),
      supabase.from('app_config').select('key,value'),
      supabase.from('stars').select('question_id'),
      supabase.from('credit_ledger').select('id').eq('reason', 'future_unlock').limit(1),
      call('todays_powerup').catch(() => null),
    ]);
    const ids = new Set();
    follows.data.forEach(f => { ids.add(f.follower); ids.add(f.followed); });
    challenges.data.forEach(c => { ids.add(c.from_user); ids.add(c.to_user); });
    predictions.data.forEach(p => p.target_user && ids.add(p.target_user));
    // Groups need the 2026-10-09 database update; until it runs, show none.
    const groupRows = groups.data || [], memberRows = members.data || [];
    memberRows.forEach(m => ids.add(m.user_id));
    const { data: people } = ids.size
      ? await supabase.from('profiles').select('id,handle,display_name').in('id', [...ids])
      : { data: [] };
    const person = Object.fromEntries(people.map(p => [p.id, p]));
    const iFollow = new Set(follows.data.filter(f => f.follower === me.id).map(f => f.followed));
    const followsMe = new Set(follows.data.filter(f => f.followed === me.id).map(f => f.follower));
    setD({
      me,
      cfg: Object.fromEntries((config.data || []).map(c => [c.key, c.value])),
      stars: new Set((stars.data || []).map(s => s.question_id)),
      questions: questions.data,
      byId: Object.fromEntries(questions.data.map(q => [q.id, q])),
      mine: Object.fromEntries(mine.data.map(s => [s.question_id, s])),
      person, iFollow, followsMe,
      friends: [...iFollow].filter(id => followsMe.has(id)).map(id => person[id]),
      challenges: challenges.data,
      predictions: predictions.data,
      futureUnlocked: (unlock.data || []).length > 0,
      powerup,
      groups: groupRows.map(g => ({ ...g, members: memberRows.filter(m => m.group_id === g.id).map(m => m.user_id) })),
    });
  }, []);
  useEffect(() => { reload(); }, [reload]);
  return [d, reload];
}

function Signed() {
  const [d, reload] = useData();
  const [tab, setTab] = useState('today');
  const [sheet, setSheet] = useState(null);
  const [feedback, setFeedback] = useState(false);
  const [toast, setToast] = useState('');
  const now = useNow(1000);
  const meId = d && d.me && d.me.id;

  // Join the group from an invite link once the profile exists.
  useEffect(() => {
    const code = meId && pendingInvite();
    if (!code) return;
    clearInvite();
    call('join_group', { p_code: code })
      .then(g => { setToast(`You joined ${g.name}. Answer a question to see how everyone answered.`); setTab('friends'); return reload(); })
      .catch(e => setToast(e.message));
  }, [meId]);
  useEffect(() => { if (toast) { const t = setTimeout(() => setToast(''), 7000); return () => clearTimeout(t); } }, [toast]);

  // Open the question from a link once the profile exists.
  const [shared, setShared] = useState(null);
  useEffect(() => {
    const code = meId && pendingQuestion();
    if (!code) return;
    clearQuestion();
    call('open_question_link', { p_code: code })
      .then(async r => { await reload(); setShared(r); setSheet(r.id); })
      .catch(e => setToast(e.message));
  }, [meId]);

  if (!d) return <div className="app" />;
  if (!d.me) return <CreateProfile onDone={reload} />;

  const inbox = d.challenges.filter(c => c.to_user === d.me.id && !c.answered_at && new Date(c.expires_at) > now);
  const ctx = { d, reload, open: setSheet, now, inbox };
  const TABS = [['today', 'today', 'Today'], ['questions', 'questions', 'Questions'], ['predict', 'predict', 'Future'], ['friends', 'group', 'Group'], ['profile', 'profile', 'Profile']];

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand"><span>yeah</span>/<em>nah</em></div>
        <div className="pills">
          <span className="pill" title="Answers left today">{d.me.answers_left_today} left</span>
          <span className="pill credits" title={`Slashes: spend ${d.cfg.send_cost ?? 2} to send a friend a question`}>{d.me.credits} {d.me.credits === 1 ? 'slash' : 'slashes'}</span>
          <button className="pill feedback" onClick={() => setFeedback(true)}>Feedback</button>
        </div>
      </header>
      {toast && <div className="note toast" role="status" onClick={() => setToast('')}>{toast}</div>}
      <main className="screen" key={tab}>
        {tab === 'today' && <Today {...ctx} />}
        {tab === 'questions' && <Questions {...ctx} />}
        {tab === 'predict' && (d.futureUnlocked ? <Predict {...ctx} /> : <FutureLocked {...ctx} />)}
        {tab === 'friends' && <Friends {...ctx} />}
        {tab === 'profile' && <Profile {...ctx} />}
      </main>
      <nav className="nav" aria-label="Main">
        {TABS.map(([k, ico, label]) => (
          <button key={k} aria-current={tab === k ? 'page' : 'false'} onClick={() => { setTab(k); setSheet(null); }}>
            <span className="ico"><Px name={ico} /></span>{label}
            {k === 'friends' && inbox.length > 0 && <span className="badge">{inbox.length}</span>}
          </button>
        ))}
      </nav>
      {feedback && <FeedbackSheet tab={tab} onClose={() => setFeedback(false)} />}
      {sheet && d.byId[sheet] && (
        <div className="scrim" onClick={e => e.target === e.currentTarget && setSheet(null)}>
          <div className="sheet" role="dialog" aria-modal="true">
            <div className="sheet-top"><button className="close" onClick={() => setSheet(null)}>Close</button></div>
            {shared && shared.id === sheet && <SharedBy shared={shared} setShared={setShared} d={d} />}
            <QuestionCard q={d.byId[sheet]} small {...ctx} />
          </div>
        </div>
      )}
    </div>
  );
}

// Above a question opened from a link: who asked, and a friend request if you aren't friends yet.
function SharedBy({ shared, setShared, d }) {
  const [error, setError] = useState('');
  if (!shared.by || shared.by_id === d.me.id) return null;
  async function follow() {
    const { error: e } = await supabase.from('follows').insert({ follower: d.me.id, followed: shared.by_id });
    if (e) setError(e.message); else setShared({ ...shared, following: true });
  }
  return (
    <div className="hook shared-by">
      {shared.by} shared this with you.{' '}
      {shared.friends ? null : shared.following
        ? `Friend request sent. You'll be friends once ${shared.by} adds you back.`
        : <button className="linkbtn" onClick={follow}>Add {shared.by} as a friend</button>}
      <Msg error={error} />
    </div>
  );
}

// A link to a question you wrote. Anyone who opens it can answer, signing up first if they need to.
function ShareLink({ q }) {
  const [url, setUrl] = useState('');
  const [note, setNote] = useState('');
  const [error, setError] = useState('');
  async function share() {
    setError(''); setNote('');
    try {
      const link = url || `${window.location.origin}/?q=${await call('share_question', { p_question: q.id })}`;
      setUrl(link);
      if (navigator.share) {
        try { await navigator.share({ title: 'yeah/nah', text: q.text, url: link }); return; }
        catch (e) { if (e.name === 'AbortError') return; }
      }
      try { await navigator.clipboard.writeText(link); setNote('Link copied. Paste it anywhere.'); }
      catch { setNote('Copy the link above.'); }
    } catch (e) { setError(e.message); }
  }
  return (
    <div className="share">
      <button type="button" className="ghost" onClick={share}><Px name="send" /> Share as a link</button>
      {url && <input readOnly value={url} onFocus={e => e.target.select()} aria-label="Link to this question" />}
      {q.status === 'pending' && <p className="hint">The link works once a moderator approves the question.</p>}
      <Msg error={error} note={note} />
    </div>
  );
}

// ---------------------------------------------------------------------------
// The question card: answer, see the split, set who sees it, send to a friend
// ---------------------------------------------------------------------------

// Who sees a new answer: sensitive ones start private; otherwise whatever you
// picked on your last vote carries over, or the app's default before that.
function startingVisibility(q, d) {
  if (q.sensitivity === 'sensitive') return 'private';
  const last = Object.values(d.mine)
    .filter(s => s.source === 'app' && d.byId[s.question_id]?.sensitivity !== 'sensitive')
    .sort((a, b) => (a.created_at < b.created_at ? 1 : -1))[0];
  const v = last ? last.visibility
    : q.sensitivity === 'personal' || d.cfg.new_answers_public === 0 ? 'friends' : 'public';
  return v === 'public' && (!d.me.is_adult || q.audience === 'friends') ? 'friends' : v;
}

// Answers to a friend question never go public, and nor do under-18s' answers.
function VisibilityPicker({ q, d, value, onChange, label }) {
  return (
    <>
      <span className="label">{label}</span>
      <div className="seg" role="group" aria-label="Visibility">
        {['public', 'friends', 'private'].filter(v => v !== 'public' || (d.me.is_adult && q.audience !== 'friends')).map(v => (
          <button key={v} aria-pressed={value === v} onClick={() => onChange(v)}>{v[0].toUpperCase() + v.slice(1)}</button>
        ))}
      </div>
    </>
  );
}

// Green for a question written for friends or sent by a friend, pink for today's question.
function tintOf(q, d) {
  if (q.audience === 'friends' || d.challenges.some(c => c.to_user === d.me.id && c.question_id === q.id)) return ' friend';
  return q.daily_date === todayUK() ? ' daily' : '';
}

function QuestionCard({ q, small, deck, noAnswers, d, reload, now, inbox, open }) {
  const mine = d.mine[q.id];
  const [vis, setVis] = useState(() => startingVisibility(q, d));
  const [split, setSplit] = useState(null);
  const [friendAns, setFriendAns] = useState([]);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [sending, setSending] = useState(false);
  const challenge = inbox.find(c => c.question_id === q.id);
  const sentBy = d.challenges.find(c => c.to_user === d.me.id && c.question_id === q.id);

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
        <p className="hint">Reveals religious or political views. Needs your opt-in and starts private.</p>
        <button className="solid" onClick={() => act('set_sensitive_opt_in', { p_on: true })}>Turn on sensitive questions</button>
      </div>
    );
  } else if (!mine && noAnswers) {
    body = <p className="hint">You've used today's answers. Questions friends send you still count, and there's a new hand tomorrow.</p>;
  } else if (!mine) {
    const opts = q.option_yes
      ? [[true, q.emoji_yes, q.option_yes], [false, q.emoji_no, q.option_no]]
      : [[true, null, 'Yeah'], [false, null, 'Nah']];
    body = (
      <>
        <VisibilityPicker q={q} d={d} value={vis} onChange={setVis} label="Who sees your answer" />
        <div className={`answer-row${deck ? ' halves' : ''}`}>
          {opts.map(([v, emoji, label]) => (
            <button key={label} className={`big ${q.option_yes ? 'pick' : v ? 'yes' : 'no'}`}
              onClick={() => act('answer', { p_question: q.id, p_value: v, p_visibility: vis })}>
              {emoji && <span className="e" aria-hidden="true">{emoji}</span>}{label}
            </button>
          ))}
        </div>
        <p className="hint">{deck ? 'Tap left or right. ' : ''}You see how everyone answered after you vote.</p>
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
            <div className={`split${q.option_yes ? ' pick' : ''}${deck ? ' tall' : ''}`} role="img" aria-label={`${pct}% ${word(q, true)}, ${100 - pct}% ${word(q, false)}`}>
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
        {hidden && <p className="hint">You changed your mind, so this stays hidden from others until {new Date(mine.hidden_until).toLocaleDateString('en-GB')}.</p>}
        {deck ? (
          <p className="hint">Seen by {mine.visibility === 'public' ? 'everyone' : mine.visibility === 'friends' ? 'your friends' : 'only you'}.{' '}
            <button className="linkbtn" onClick={() => open(q.id)}>Change</button></p>
        ) : (
          <VisibilityPicker q={q} d={d} value={mine.visibility} label="Who sees this answer on your profile"
            onChange={v => act('set_visibility', { p_question: q.id, p_visibility: v })} />
        )}
        {!deck && !mine.verified && (d.me.changes_left_today > 0
          ? <button className="linkbtn" onClick={() => act('answer', { p_question: q.id, p_value: !mine.value }, 'Changed. That was today\'s change of mind.')}>
              Change my answer to {word(q, !mine.value).toLowerCase()} (1 a day)</button>
          : <p className="hint">You've used today's change of mind.</p>)}
        {q.created_by === d.me.id && <ShareLink q={q} />}
        {canSend && (sending
          ? <SendPanel q={q} d={d} reload={reload} friendAns={friendAns} onClose={() => setSending(false)} />
          : <button className="ghost send-btn" onClick={() => setSending(true)}><Px name="send" /> Send to friends or a group</button>)}
      </>
    );
  }

  return (
    <div className={`card${small ? ' small' : ''}${deck ? ' deck-card' : ''}${tintOf(q, d)}`}>
      <Chips q={q}>
        {q.daily_date === todayUK() && <span className="chip daily">Today's question</span>}
        {starrable(q) && (deck ? d.stars.has(q.id) : !mine || d.stars.has(q.id)) && <StarToggle q={q} d={d} reload={reload} chip />}
        {sentBy ? <span className="chip friend">From {d.person[sentBy.from_user]?.display_name || 'a friend'}</span>
          : q.audience === 'friends' && <span className="chip friend">{q.created_by === d.me.id ? 'Your question'
            : d.person[q.created_by] ? `By ${d.person[q.created_by].display_name}` : 'Shared with you'}</span>}
        {challenge && <span className="chip timer"><Px name="timer" scale={1} /> {left(challenge.expires_at, now)}</span>}
      </Chips>
      <h2 className="qtext">{q.text}</h2>
      {challenge && !mine && <p className="hint">Answer before the timer runs out for {d.cfg.challenge_reward ?? 2} slashes. Doesn't count towards your daily answers.</p>}
      {body}
      <Msg error={error} note={note} />
    </div>
  );
}

// Pick friends one by one, or a whole group at once. blocked(handle) gives a
// reason someone can't be picked, such as having answered already.
function FriendPicker({ d, picked, setPicked, blocked = () => '' }) {
  const friends = d.friends.filter(Boolean);
  const groups = d.groups
    .map(g => ({ ...g, handles: g.members.map(id => d.person[id]?.handle).filter(h => h && friends.some(f => f.handle === h) && !blocked(h)) }))
    .filter(g => g.handles.length);
  const toggle = h => setPicked(p => (p.includes(h) ? p.filter(x => x !== h) : [...p, h]));
  const toggleGroup = g => setPicked(p => (g.handles.every(h => p.includes(h))
    ? p.filter(h => !g.handles.includes(h)) : [...new Set([...p, ...g.handles])]));
  return (
    <div className="picker">
      {groups.length > 0 && (
        <div className="chips">
          {groups.map(g => (
            <button type="button" key={g.id} className="chip group" aria-pressed={g.handles.every(h => picked.includes(h))} onClick={() => toggleGroup(g)}>
              Everyone in {g.name}
            </button>
          ))}
        </div>
      )}
      <div className="chips">
        {friends.map(f => (
          <button type="button" key={f.handle} className="chip" aria-pressed={picked.includes(f.handle)} disabled={!!blocked(f.handle)} onClick={() => toggle(f.handle)}>
            {f.display_name}{blocked(f.handle) ? ` · ${blocked(f.handle)}` : ''}
          </button>
        ))}
      </div>
    </div>
  );
}

// Send a question you've answered to friends.
function SendPanel({ q, d, reload, friendAns, onClose }) {
  const cost = q.audience === 'friends' ? 0 : d.cfg.send_cost ?? 2;
  const [picked, setPicked] = useState([]);
  const [timer, setTimer] = useState(1440);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const nameOf = h => d.friends.find(f => f && f.handle === h)?.display_name || h;
  const answered = new Set(friendAns.map(f => f.handle));
  const sent = new Set(d.challenges.filter(c => c.from_user === d.me.id && c.question_id === q.id).map(c => d.person[c.to_user]?.handle));
  const blocked = h => (answered.has(h) ? 'answered' : sent.has(h) ? 'sent' : '');
  const total = picked.length * cost;

  async function send() {
    setBusy(true); setError(''); setNote('');
    const ok = [], bad = [];
    for (const h of picked) {
      try { await call('send_challenge', { p_handle: h, p_question: q.id, p_minutes: timer }); ok.push(nameOf(h)); }
      catch (e) { bad.push(`${nameOf(h)}: ${e.message}.`); }
    }
    setPicked([]); setBusy(false);
    if (ok.length) setNote(`Sent to ${ok.join(', ')}. The clock is ticking.`);
    if (bad.length) setError(bad.join(' '));
    await reload();
  }

  return (
    <div className="panel send">
      <span className="label">Send to friends: {cost ? `${cost} slashes each` : 'free for a friend question'}. They get {d.cfg.challenge_reward ?? 2} if they answer in time.</span>
      <FriendPicker d={d} picked={picked} setPicked={setPicked} blocked={blocked} />
      <div className="seg" role="group" aria-label="Timer">
        {TIMERS.map(([m, l]) => <button key={m} aria-pressed={timer === m} onClick={() => setTimer(m)}>{l}</button>)}
      </div>
      <div className="inline">
        <button className="solid" disabled={!picked.length || busy || total > d.me.credits} onClick={send}>
          {busy ? 'Sending…' : picked.length ? `Send to ${picked.length} · ${total ? `${total} slashes` : 'free'}` : 'Pick who gets it'}
        </button>
        <button className="linkbtn" onClick={onClose}>Close</button>
      </div>
      {total > d.me.credits && <p className="hint">You have {d.me.credits} slashes.</p>}
      <Msg error={error} note={note} />
    </div>
  );
}

function Row({ q, d, open, extra, reload, star }) {
  const mine = d.mine[q.id];
  const locked = q.sensitivity === 'sensitive' && !d.me.sensitive_opt_in;
  const row = (
    <button className="row" onClick={() => open(q.id)}>
      <span><span className="t">{q.text}</span><Chips q={q}>{extra}</Chips></span>
      <span>{locked ? <Px name="lock" label="Locked" /> : mine ? <Pill q={q} v={mine.value} /> : null}</span>
    </button>
  );
  return star && starrable(q) ? <div className="row-star">{row}<StarToggle q={q} d={d} reload={reload} /></div> : row;
}

// Starred questions you haven't answered are dealt into Today first. Questions
// written for friends and world events aren't dealt, so they can't be starred.
const starrable = q => q.audience !== 'friends' && !q.is_event;
function StarToggle({ q, d, reload, chip }) {
  const [on, setOn] = useState(d.stars.has(q.id));
  const [error, setError] = useState('');
  useEffect(() => setOn(d.stars.has(q.id)), [d.stars, q.id]);
  async function toggle(e) {
    e.stopPropagation();
    const next = !on;
    setOn(next); setError('');
    try { await call('set_star', { p_question: q.id, p_on: next }); await reload(); }
    catch (err) { setOn(!next); setError(err.message); }
  }
  const label = on ? 'Starred' : 'Star';
  return (
    <button className={chip ? 'chip star' : 'star-btn'} aria-pressed={on} onClick={toggle}
      aria-label={chip ? undefined : `Star: ${q.text}`} title={error || (on ? 'Starred: comes up first in Today' : 'Star it to get it in Today')}>
      <Px name={on ? 'star-on' : 'star'} />{chip && ` ${label}`}
    </button>
  );
}

// ---------------------------------------------------------------------------
// Tabs
// ---------------------------------------------------------------------------

function shuffle(xs) {
  const a = [...xs];
  for (let i = a.length - 1; i > 0; i--) { const j = Math.floor(Math.random() * (i + 1)); [a[i], a[j]] = [a[j], a[i]]; }
  return a;
}

// Puts each id at a random spot among the next few cards after `from`, so
// questions friends send turn up soon (they're on a timer) but mixed in.
function shuffleIn(deck, newIds, from) {
  const out = [...deck];
  for (const id of newIds) {
    const at = from + 1 + Math.floor(Math.random() * Math.min(4, out.length - from));
    out.splice(Math.min(at, out.length), 0, id);
  }
  return out;
}

// Unanswered questions in a random order, mixed so the same theme doesn't come up twice in a row.
function interleave(qs) {
  qs = shuffle(qs);
  const byCat = {};
  qs.forEach(q => (byCat[q.category] || (byCat[q.category] = [])).push(q));
  const lists = Object.values(byCat), out = [];
  for (let i = 0; out.length < qs.length; i++) lists.forEach(l => l[i] && out.push(l[i]));
  return out;
}

// Questions that can be dealt: approved, unanswered, not today's or a future
// daily, and sensitive ones only if you've opted in.
function dealable(d, today, skip) {
  const qs = interleave(d.questions.filter(q => !q.is_event && q.status === 'approved' && !d.mine[q.id]
    && (!q.daily_date || q.daily_date < today) && !skip.has(q.id)
    && (q.sensitivity !== 'sensitive' || d.me.sensitive_opt_in)));
  // Questions friends wrote come first, then starred ones, then the rest.
  const rank = q => (q.audience === 'friends' ? 0 : d.stars.has(q.id) ? 1 : 2);
  return [0, 1, 2].flatMap(r => qs.filter(q => rank(q) === r).map(q => q.id));
}

// Power-ups: some days the first hand has one in it. For now each one holds
// slashes to claim; rarer ones hold more. It's a card in the hand like any
// other, under the id PU, and stays there once claimed.
const PU = 'powerup';
const RARITY = ['common', 'uncommon', 'rare', 'epic', 'legendary'];
function PowerUpCard({ p, reload }) {
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const level = RARITY.indexOf(p.rarity) + 1;
  const unit = p.slashes === 1 ? 'slash' : 'slashes';
  async function claim() {
    setError(''); setBusy(true);
    try { await call('claim_powerup'); await reload(); } catch (e) { setError(e.message); }
    setBusy(false);
  }
  return (
    <div className={`card deck-card powerup ${p.rarity}${p.claimed ? ' claimed' : ''}`}>
      <div className="chips">
        <span className="chip rarity">{p.rarity}</span>
        <span className="pips" role="img" aria-label={`Rarity ${level} of 5`}>
          {RARITY.map((r, k) => <i key={r} className={k < level ? 'on' : ''} />)}
        </span>
        <span className="chip">Power-up</span>
      </div>
      <div className="pu-art" aria-hidden="true">
        <span className="n">+{p.slashes}</span>
        <span className="w">{unit}</span>
      </div>
      <h2 className="qtext">{p.name}</h2>
      <p className="hint">{p.blurb}</p>
      {p.claimed
        ? <p className="pu-done"><Px name="check" /> Claimed. {p.slashes} {unit} added.</p>
        : <button className="solid pu-claim" onClick={claim} disabled={busy}>Claim {p.slashes} {unit}</button>}
      <p className="hint">
        {p.odds ? `${p.odds}% of power-ups are ${p.name}. ` : ''}
        {p.claimed ? 'Another power-up could turn up in a future first hand.' : 'Gone at midnight if you don\'t claim it.'}
      </p>
      <Msg error={error} />
    </div>
  );
}

// Today's hand is kept on this device, so it survives tab switches and reloads.
// A new hand is dealt each UK day and older ones are cleared out.
const HAND_KEY = 'yeahnah-hand-';
function loadHand(uid, date) {
  try { return JSON.parse(localStorage.getItem(`${HAND_KEY}${uid}-${date}`)); } catch { return null; }
}
function saveHand(uid, date, hand) {
  try {
    for (let k = localStorage.length - 1; k >= 0; k--) {
      const key = localStorage.key(k);
      if (key && key.startsWith(`${HAND_KEY}${uid}-`) && !key.endsWith(date)) localStorage.removeItem(key);
    }
    localStorage.setItem(`${HAND_KEY}${uid}-${date}`, JSON.stringify(hand));
  } catch { /* private window or storage blocked: the hand just lasts until reload */ }
}

function Today(ctx) {
  const { d, inbox } = ctx;
  const today = todayUK();
  const uid = d.me.id;
  const size = d.cfg.answers_per_day || 5;
  const daily = d.questions.find(q => q.daily_date === today);
  const inboxIds = [...new Set(inbox.map(c => c.question_id))];
  // Everything you answered today stays in the stack, wherever you answered it,
  // so the stack is the same on every device.
  const answeredToday = Object.values(d.mine)
    .filter(st => st.source === 'app' && d.byId[st.question_id]
      && new Date(st.created_at).toLocaleDateString('en-CA', { timeZone: 'Europe/London' }) === today)
    .sort((a, b) => (a.created_at < b.created_at ? -1 : 1))
    .map(st => st.question_id);
  // Five cards a day: today's question first, then what you've answered today,
  // then enough you haven't answered to make five, in a shuffled order.
  // Questions friends send you are extra cards on top.
  const [hand, setHand] = useState(() => {
    const kept = loadHand(uid, today);
    if (kept && Array.isArray(kept.ids)) {
      const ids = kept.ids.filter(id => (id === PU ? d.powerup : d.byId[id]));
      return { ids, i: Math.min(kept.i || 0, Math.max(ids.length - 1, 0)), seen: kept.seen || ids };
    }
    const first = daily ? [daily.id] : [];
    const done = answeredToday.filter(id => !first.includes(id));
    // Enough to make five, or as many answers as you have left today if that's more.
    const left = daily ? d.me.other_answers_left_today : d.me.answers_left_today;
    const fresh = dealable(d, today, new Set([...first, ...done, ...inboxIds])).slice(0, Math.max(size - first.length - done.length, left, 0));
    const ids = [...first, ...done, ...fresh];
    // Today's power-up, if there is one, goes somewhere after the first card you haven't answered.
    if (d.powerup) ids.splice(first.length + done.length + 1 + Math.floor(Math.random() * fresh.length), 0, PU);
    return { ids, i: Math.max(ids.findIndex(id => !d.mine[id]), 0), seen: ids };
  });
  // Something answered outside the stack today (in Questions, or on another device) joins it at the end.
  useEffect(() => {
    setHand(h => {
      const missing = answeredToday.filter(id => !h.ids.includes(id));
      return missing.length ? { ...h, ids: [...h.ids, ...missing], seen: [...new Set([...h.seen, ...missing])] } : h;
    });
  }, [answeredToday.join()]);
  // A friend's question is shuffled into the next few cards, including ones that arrive while you're here.
  useEffect(() => {
    setHand(h => {
      const fresh = inboxIds.filter(id => d.byId[id] && !h.ids.includes(id));
      return fresh.length ? { ...h, ids: shuffleIn(h.ids, fresh, h.i), seen: [...h.seen, ...fresh] } : h;
    });
  }, [inbox.map(c => c.id).join()]);
  // A hand dealt before today's power-up was known gets it shuffled into the next few cards.
  useEffect(() => {
    setHand(h => {
      const has = h.ids.includes(PU);
      if (!!d.powerup === has) return h;
      if (d.powerup) return { ...h, ids: shuffleIn(h.ids, [PU], h.i), seen: [...new Set([...h.seen, PU])] };
      const k = h.ids.indexOf(PU), ids = h.ids.filter(id => id !== PU);
      return { ...h, ids, i: Math.max(0, Math.min(h.i > k ? h.i - 1 : h.i, ids.length - 1)) };
    });
  }, [!!d.powerup]);
  useEffect(() => saveHand(uid, today, hand), [hand]);

  const [note, setNote] = useState('');
  const date = new Date().toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'Europe/London' });

  const n = hand.ids.length;
  const byFriend = id => d.byId[id]?.audience === 'friends';
  // Today's question, questions friends sent you and friends wrote don't use up your daily answers.
  const counts = id => id === daily?.id || inboxIds.includes(id) || byFriend(id);
  const fromFriend = id => d.challenges.some(c => c.to_user === uid && c.question_id === id);
  // Today's question, questions friends sent and starred ones stay put until answered.
  const canSwap = id => id !== PU && !d.mine[id] && id !== daily?.id && !fromFriend(id) && !d.stars.has(id);
  const swappable = hand.ids.filter(canSwap);
  // Questions friends wrote and questions starred since the hand was dealt take the
  // place of other unanswered cards, starting from the back and never the card on top.
  const friendQs = d.questions.filter(x => x.audience === 'friends' && !d.mine[x.id]).map(x => x.id);
  useEffect(() => {
    setHand(h => {
      const want = [
        ...dealable(d, today, new Set([...h.ids, ...h.seen])).filter(byFriend),
        ...dealable(d, today, new Set(h.ids)).filter(id => d.stars.has(id) && !byFriend(id)),
      ];
      if (!want.length) return h;
      const ids = [...h.ids];
      for (let k = ids.length - 1; k >= 0 && want.length; k--) {
        if (k !== h.i && canSwap(ids[k]) && !byFriend(ids[k])) ids[k] = want.shift();
      }
      return ids.join() === h.ids.join() ? h : { ...h, ids, seen: [...new Set([...h.seen, ...ids])] };
    });
  }, [[...d.stars].join(), friendQs.join()]);
  const done = hand.ids.filter(id => d.mine[id]).length;

  const step = by => setHand(h => ({ ...h, i: (h.i + by + h.ids.length) % h.ids.length }));
  // Each card's place in the stack: 0 on top, then the ones after it, wrapping round the hand.
  const slots = Object.fromEntries(hand.ids.map((id, k) => [id, (k - hand.i + n) % n]));
  const motion = useDeckMotion({ slots, can: n > 1, pop: done + (d.powerup?.claimed ? 1 : 0), onSwipe: dir => (dir < 0 ? step(1) : step(-1)) });
  // Swipe left (or Next) sends the top card to the back of the stack; swipe right (or Back) brings the last one back.
  function forward() {
    if (n < 2) return;
    setNote(''); motion.dir(-1); step(1);
  }
  function back() {
    if (n < 2) return;
    setNote(''); motion.dir(1); step(-1);
  }
  function jump(k) {
    if (k === hand.i) return;
    setNote(''); motion.dir(k < hand.i ? 1 : -1); setHand(h => ({ ...h, i: k }));
  }
  // Shuffle only ever swaps unanswered cards, for ones you haven't seen today,
  // friends' questions first. Answered cards stay, and so do today's question,
  // questions friends sent and starred ones until you answer them.
  function reshuffle() {
    const fresh = dealable(d, today, new Set([...hand.ids, ...hand.seen]));
    const pool = fresh.length >= swappable.length ? fresh
      : [...fresh, ...dealable(d, today, new Set([...hand.ids, ...fresh]))];
    if (!pool.length) { setNote('No other questions left to swap in.'); return; }
    let k = 0;
    const ids = hand.ids.map(id => (swappable.includes(id) && k < pool.length ? pool[k++] : id));
    setHand(h => ({ ...h, ids, seen: [...new Set([...h.seen, ...ids])] }));
    setNote(`Swapped ${k} card${k === 1 ? '' : 's'}.`);
  }
  useEffect(() => {
    const key = e => {
      if (document.querySelector('.scrim') || (e.target.closest && e.target.closest('input, select, textarea'))) return;
      if (e.key === 'ArrowRight') forward();
      if (e.key === 'ArrowLeft') back();
    };
    window.addEventListener('keydown', key);
    return () => window.removeEventListener('keydown', key);
  });

  return (
    <>
      <div className="head">
        <span className="eyebrow">{date} · {n ? `Card ${hand.i + 1} of ${n} · ${done} answered` : 'All done'}</span>
      </div>
      {!n ? (
        <div className="card deck-end">
          <h2 className="qtext">You've seen them all</h2>
          <p className="hint">New questions arrive every day. Suggest one in the Questions tab.</p>
        </div>
      ) : (
        <div className="deck">
          {hand.ids.filter(id => (id === PU ? d.powerup : d.byId[id])).map(id => (
            <div key={id} ref={motion.cardRef(id)} className={`slot${slots[id] === 0 ? ' top' : ''}`}>
              {id === PU ? <PowerUpCard p={d.powerup} reload={ctx.reload} />
                : <QuestionCard q={d.byId[id]} deck noAnswers={!d.mine[id] && !counts(id) && d.me.other_answers_left_today <= 0} {...ctx} />}
            </div>
          ))}
        </div>
      )}
      {n > 0 && (
        <>
          <div className="deck-nav">
            <button className="ghost" onClick={back} disabled={n < 2} aria-label="Previous card">‹ Back</button>
            <div className="dots" aria-label="Cards in today's hand">
              {hand.ids.map((id, k) => (id === PU ? (
                <button key={id} className={`dot powerup ${d.powerup?.rarity}${d.powerup?.claimed ? ' done' : ''}`} aria-current={k === hand.i}
                  aria-label={`Card ${k + 1}, power-up${d.powerup?.claimed ? ', claimed' : ''}`} onClick={() => jump(k)} />
              ) : (
                <button key={id} className={`dot${d.mine[id] ? ' done' : ''}${tintOf(d.byId[id], d)}`} aria-current={k === hand.i}
                  aria-label={`Card ${k + 1}${d.mine[id] ? ', answered' : ''}`} onClick={() => jump(k)} />
              )))}
            </div>
            <button className="ghost" onClick={forward} disabled={n < 2} aria-label="Next card">Next ›</button>
          </div>
          <div className="deck-nav">
            <span className="hint">{note || 'Swipe left for the next card, right to go back.'}</span>
            <button className="ghost" onClick={reshuffle} disabled={!swappable.length}><Px name="shuffle" /> Shuffle</button>
          </div>
        </>
      )}
      <p className="hint" style={{ marginTop: 10 }}>
        {d.me.other_answers_left_today > 0
          ? `${d.me.other_answers_left_today} more answer${d.me.other_answers_left_today === 1 ? '' : 's'} today, with one always kept for the daily question.`
          : 'That\'s your answers for today. Questions friends send you still count.'}
      </p>
    </>
  );
}

function Questions(ctx) {
  const { d, inbox } = ctx;
  const [filter, setFilter] = useState('all');
  const [theme, setTheme] = useState(null);
  const sent = new Set(inbox.map(c => c.question_id));
  const F = { all: 'All', open: 'Not answered', starred: 'Starred', sent: 'Sent to you', standard: 'Standard', personal: 'Personal', sensitive: 'Sensitive' };
  const qs = d.questions.filter(q => !q.is_event && q.status === 'approved');
  const byTheme = {};
  for (const q of qs) {
    const t = byTheme[q.category] || (byTheme[q.category] = { name: q.category, total: 0, done: 0 });
    t.total++;
    if (d.mine[q.id]) t.done++;
  }
  const themes = Object.values(byTheme).sort((a, b) => b.total - a.total || a.name.localeCompare(b.name));
  const list = qs.filter(q => (!theme || q.category === theme)
    && (filter === 'all' || (filter === 'open' ? !d.mine[q.id] : filter === 'starred' ? d.stars.has(q.id)
      : filter === 'sent' ? sent.has(q.id) : q.sensitivity === filter)));
  const starredOpen = qs.filter(q => d.stars.has(q.id) && !d.mine[q.id]).length;
  const picked = byTheme[theme];
  return (
    <>
      <MakeQuestion {...ctx} themes={themes.map(t => t.name).filter(n => n !== 'Friends')} />
      <div className="themes" role="group" aria-label="Themes">
        {themes.map(t => (
          <button key={t.name} className="theme" aria-pressed={theme === t.name} onClick={() => setTheme(theme === t.name ? null : t.name)}>
            <span className="e"><Px name={t.name} /></span>
            <span className="n">{t.done}/{t.total}</span>
            <b>{t.name}</b>
            <span className="bar"><i style={{ width: `${(100 * t.done) / t.total}%` }} /></span>
          </button>
        ))}
      </div>
      <div className="filters" role="group" aria-label="Filter">
        {Object.entries(F).map(([k, v]) => <button key={k} aria-pressed={filter === k} onClick={() => setFilter(k)}>{v}</button>)}
      </div>
      <p className="hint" style={{ margin: '4px 2px 10px' }}>
        {picked
          ? <>{picked.name}: {picked.done} of {picked.total} answered · showing {list.length} · <button className="linkbtn" onClick={() => setTheme(null)}>All themes</button></>
          : <>{Object.keys(d.mine).length} answered · showing {list.length}</>}
        <br />{starredOpen
          ? `${starredOpen} starred to answer. They're dealt into Today after friends' questions.`
          : 'Star a question to get it in your Today hand.'}
      </p>
      <div className="rows">{list.map(q => <Row key={q.id} q={q} {...ctx} star />)}</div>
    </>
  );
}

// Write a question. For friends it's live straight away and goes to the friends
// you pick; for everyone it waits for a moderator.
function MakeQuestion({ d, reload, themes }) {
  const [kind, setKind] = useState('friends');
  const [text, setText] = useState('');
  const [value, setValue] = useState(null);
  const [picked, setPicked] = useState([]);
  const [timer, setTimer] = useState(1440);
  const [theme, setTheme] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const fq = d.cfg.friend_question_cost ?? 3, pub = d.cfg.public_question_cost ?? 5;
  const forFriends = kind === 'friends';
  const cost = forFriends ? fq : pub;
  const open = text.length > 0;
  const waiting = d.questions.filter(q => q.created_by === d.me.id && q.status === 'pending');
  const ready = text.trim().length >= 5 && (!forFriends || value !== null);
  const [made, setMade] = useState(null);
  const nameOf = h => d.friends.find(f => f && f.handle === h)?.display_name || h;

  async function submit(e) {
    e.preventDefault(); setError(''); setNote(''); setBusy(true);
    try {
      if (forFriends) {
        setMade(await call('make_friend_question', { p_text: text, p_value: value, p_handles: picked, p_minutes: timer }));
        setNote(`${picked.length ? `Sent to ${picked.map(nameOf).join(', ')}. ` : 'Made. '}Share the link so anyone can answer it.`);
      } else {
        setMade(await call('submit_question', { p_text: text, p_category: theme || 'General' }));
        setNote('Thanks. A moderator checks it before it goes live for everyone.');
      }
      setText(''); setValue(null); setPicked([]);
      await reload();
    } catch (err) { setError(err.message); }
    setBusy(false);
  }

  return (
    <form className="section make" onSubmit={submit}>
      <h2>Make a question</h2>
      <div className="seg" role="group" aria-label="Who it's for">
        <button type="button" aria-pressed={forFriends} onClick={() => setKind('friends')}>For friends</button>
        <button type="button" aria-pressed={!forFriends} onClick={() => setKind('public')}>For everyone</button>
      </div>
      <input required minLength={5} maxLength={140} aria-label="Your question" value={text} onChange={e => { setText(e.target.value); setMade(null); }}
        placeholder={forFriends ? 'Would you eat a bug for a tenner?' : 'Is cereal a soup?'} />
      <p className="hint">{forFriends
        ? `Only your friends and people you share the link with can see it, so there's no approval. ${fq} slashes, however many friends you send it to, and passing it on is free.`
        : `A moderator checks it before it goes live for everyone. ${pub} slashes, up to 3 a day.`}</p>
      {!open ? null : forFriends ? (d.friends.length === 0
        ? <p className="hint">Add friends in the Group tab first.</p>
        : (
          <>
            <span className="label">Your answer</span>
            <div className="seg" role="group" aria-label="Your answer">
              <button type="button" aria-pressed={value === true} onClick={() => setValue(true)}>Yeah</button>
              <button type="button" aria-pressed={value === false} onClick={() => setValue(false)}>Nah</button>
            </div>
            <span className="label">Send it to (optional: you can share a link instead)</span>
            <FriendPicker d={d} picked={picked} setPicked={setPicked} />
            <div className="seg" role="group" aria-label="Timer">
              {TIMERS.map(([m, l]) => <button type="button" key={m} aria-pressed={timer === m} onClick={() => setTimer(m)}>{l}</button>)}
            </div>
          </>
        )) : (
        <select value={theme} onChange={e => setTheme(e.target.value)} aria-label="Theme">
          <option value="">Pick a theme (optional)</option>
          {themes.map(t => <option key={t}>{t}</option>)}
        </select>
      )}
      {open && <button className="solid" disabled={!ready || busy || cost > d.me.credits}>
        {busy ? 'Sending…' : forFriends ? `${picked.length ? 'Make and send' : 'Make it'} · ${cost} slashes` : `Send for review · ${cost} slashes`}
      </button>}
      {open && cost > d.me.credits && <p className="hint">You have {d.me.credits} slashes. Answering a friend's question in time earns {d.cfg.challenge_reward ?? 2}.</p>}
      <Msg error={error} note={note} />
      {made && d.byId[made] && <ShareLink q={d.byId[made]} />}
      {waiting.length > 0 && <p className="hint">Waiting for a moderator: {waiting.map(q => `"${q.text}"`).join(', ')}</p>}
    </form>
  );
}

// Future starts locked: it costs slashes once, which keeps throwaway accounts
// out, and needs a date of birth showing 18 or over. The server checks both.
function FutureLocked({ d, reload }) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const cost = d.cfg.future_unlock_cost ?? 100;
  const enough = d.me.credits >= cost;
  const ready = enough && d.me.is_adult;
  async function unlock() {
    setError(''); setBusy(true);
    try { await call('unlock_future'); await reload(); }
    catch (e) { setError(e.message); }
    setBusy(false);
  }
  const Need = ({ ok, children }) => <li><Px name={ok ? 'check' : 'cross'} label={ok ? 'Done' : 'Not yet'} /> {children}</li>;
  return (
    <>
      <div className="section"><h2>Future is locked</h2>
        <div className="panel">
          <span>Guess how everyone will answer today's question, what your friends will say, and what will happen in the world. Every guess builds a hit rate on your profile.</span>
          <ul className="needs">
            <Need ok={enough}>{cost} slashes, once. You have {d.me.credits}.</Need>
            <Need ok={d.me.is_adult}>A date of birth on your profile showing you're 18 or over.</Need>
          </ul>
          <button className="solid" disabled={!ready || busy} onClick={unlock}>{busy ? 'Unlocking…' : `Unlock Future · ${cost} slashes`}</button>
          {!enough && <p className="hint">Answering a friend's question in time earns {d.cfg.challenge_reward ?? 2}. New accounts start with {d.cfg.signup_credits ?? 10}, so the unlock keeps throwaway accounts out.</p>}
          <Msg error={error} />
        </div>
      </div>
      <NoHouse />
    </>
  );
}

const NoHouse = () => (
  <div className="section"><h2>There's no house</h2>
    <div className="panel">
      <span>At a bookmaker, the house sets the odds and builds in an edge, so over time the house wins. A prediction market has no house: people predict against each other, the odds are simply what the crowd thinks, and nobody gains when you're wrong.</span>
      <span>Future works the same way. Nobody here sets odds or takes a cut. Your guesses are scored only against what really happens, and your hit rate is yours.</span>
    </div>
  </div>
);

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
      <p className="hint" style={{ marginTop: 8 }}>Guesses are free now Future is unlocked. Your hit rate shows on your profile.</p>
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

      <NoHouse />
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
      <Groups d={d} reload={reload} open={open} />
      <div className="section"><h2>Add someone by handle</h2></div>
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
                // Cards carry the id since the 2026-10-11 database update; before it, look it up.
                const id = card.id || (await supabase.from('profiles').select('id').eq('handle', card.handle).single()).data?.id;
                follow(id, true);
              }}>{card.follows_me ? 'Follow back' : 'Follow'}</button>}
        </div>
      )}

      {inbox.length > 0 && (
        <div className="section"><h2>Sent to you</h2>
          {inbox.map(c => (
            <button key={c.id} className="row" onClick={() => open(c.question_id)}>
              <span><span className="t">{d.byId[c.question_id]?.text}</span><span className="hint">from {d.person[c.from_user]?.display_name}</span></span>
              <span className="chip timer"><Px name="timer" scale={1} /> {left(c.expires_at, now)}</span>
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
          c.answered_at ? 'answered in time' : new Date(c.expires_at) > now ? <><Px name="timer" scale={1} /> {left(c.expires_at, now)}</> : 'ran out of time'}</p>
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
        <span className="hint">@{d.me.handle}{d.me.is_adult ? '' : ' · Friends-only profile'}</span>
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
              ? 'On. These answers start private. Turning this off makes them all private.'
              : 'Off. We record when you agree so you can withdraw at any time.'}</p></div>
        </div>
      )}

      <div className="section"><h2>Your data</h2>
        <div className="panel">
          <p className="hint"><PrivacyLink>How we handle your data</PrivacyLink></p>
          <button className="ghost" onClick={download}>Download my data</button>
          <button className="ghost" onClick={() => supabase.auth.signOut()}>Sign out</button>
          <button className="ghost danger" onClick={del}>Delete my account</button>
        </div>
      </div>
    </>
  );
}

// ---------------------------------------------------------------------------
// Friend groups: an invite link, and everyone's answers per question
// ---------------------------------------------------------------------------

function Groups({ d, reload, open }) {
  const [sel, setSel] = useState(null);
  const [name, setName] = useState('');
  const [board, setBoard] = useState(null);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const g = d.groups.find(x => x.id === sel) || d.groups[0];

  useEffect(() => {
    if (!g) return;
    call('group_board', { p_group: g.id }).then(setBoard).catch(e => setError(e.message));
  }, [g && g.id, d]);

  async function act(fn, args, done) {
    setError(''); setNote('');
    try { const r = await call(fn, args); if (done) setNote(done); await reload(); return r; } catch (e) { setError(e.message); }
  }
  async function create(e) {
    e.preventDefault();
    const r = await act('create_group', { p_name: name }, 'Group made. Now share the invite.');
    if (r) { setName(''); setSel(r.id); }
  }
  async function share() {
    const link = `${window.location.origin}/?join=${g.invite_code}`;
    const text = `Join my yeah/nah group "${g.name}". One yes/no question a day, and we see how each other answered. It's an early test, so tap Feedback and tell me what you think.`;
    setError(''); setNote('');
    if (navigator.share) {
      try { await navigator.share({ title: 'yeah/nah', text, url: link }); return; } catch (err) { if (err.name === 'AbortError') return; }
    }
    try { await navigator.clipboard.writeText(`${text} ${link}`); setNote('Invite copied. Paste it into WhatsApp or a text. Anyone with the link can join, so only send it to friends.'); }
    catch { setNote(`Send your friends this link: ${link}`); }
  }

  const makeForm = d.me.is_adult && (
    <form className="inline" onSubmit={create}>
      <input required maxLength={40} placeholder="Group name, e.g. Pub quiz lot" value={name} onChange={e => setName(e.target.value)} aria-label="Group name" />
      <button className="ghost">Make</button>
    </form>
  );

  if (!g) {
    return (
      <div className="section"><h2>Your group</h2>
        <p className="hint">{d.me.is_adult
          ? 'Make a group and share the invite link. Everyone who joins sees how each other answered every question, once they have answered it too.'
          : 'Groups aren\'t available on your account yet.'}</p>
        {makeForm}
        <Msg error={error} note={note} />
      </div>
    );
  }

  const rows = (board || []).filter(r => d.byId[r.question_id]);
  const people = g.members.map(id => d.person[id]).filter(Boolean);
  return (
    <div className="section">
      {d.groups.length > 1 && (
        <div className="filters" role="group" aria-label="Group">
          {d.groups.map(x => <button key={x.id} aria-pressed={x.id === g.id} onClick={() => setSel(x.id)}>{x.name}</button>)}
        </div>
      )}
      <h2>{g.name}</h2>
      <div className="chips">{people.map(p => <span key={p.id} className="chip">{p.id === d.me.id ? 'You' : p.display_name}</span>)}</div>
      <button className="solid" onClick={share}>Invite friends</button>
      <Msg error={error} note={note} />

      <h3 style={{ marginTop: 8 }}>How everyone answered</h3>
      {board === null && <p className="empty">Loading…</p>}
      {board && rows.length === 0 && <p className="empty">No answers yet. Start with today's question.</p>}
      <div className="rows">
        {rows.map(r => {
          const q = d.byId[r.question_id];
          return (
            <button key={r.question_id} className="row" onClick={() => open(q.id)}>
              <span>
                <span className="t">{q.text}</span>
                {r.answers
                  ? <span className="chips">{r.answers.map(a => (
                      <span key={a.handle} className={`vpill ${pillClass(q, a.value)}`}>{a.me ? 'You' : a.name}: {word(q, a.value)}</span>))}</span>
                  : <span className="hint">{r.answered} of {people.length} answered. Answer it to see who said what.</span>}
              </span>
              <span>{r.answers ? '' : <Px name="lock" label="Locked" />}</span>
            </button>
          );
        })}
      </div>
      <div className="inline" style={{ justifyContent: 'space-between', marginTop: 6 }}>
        {g.created_by === d.me.id
          ? <button className="linkbtn" onClick={() => act('reset_invite', { p_group: g.id }, 'New invite link made. The old one no longer works.')}>Reset invite link</button>
          : <span />}
        <button className="linkbtn danger" onClick={() => window.confirm(`Leave ${g.name}? You stop being friends with people you only know through it.`) && act('leave_group', { p_group: g.id })}>Leave group</button>
      </div>
      {g.created_by === d.me.id && people.length > 1 && (
        <details><summary className="hint">Remove someone</summary>
          <div className="chips" style={{ marginTop: 8 }}>
            {people.filter(p => p.id !== d.me.id).map(p => (
              <button key={p.id} className="chip" onClick={() => window.confirm(`Remove ${p.display_name} from ${g.name}? They won't be able to rejoin with the invite link.`)
                && act('remove_member', { p_group: g.id, p_user: p.id }, `${p.display_name} was removed.`)}>{p.display_name} <Px name="close" scale={1} /></button>
            ))}
          </div>
        </details>
      )}
      {d.me.is_adult && d.groups.length < 5 && <details><summary className="hint">Make another group</summary>{makeForm}</details>}
    </div>
  );
}

function FeedbackSheet({ tab, onClose }) {
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);
  async function submit(e) {
    e.preventDefault(); setError('');
    try { await call('submit_feedback', { p_body: text, p_context: tab }); setSent(true); setText(''); }
    catch (err) { setError(err.message); }
  }
  return (
    <div className="scrim" onClick={e => e.target === e.currentTarget && onClose()}>
      <form className="sheet" role="dialog" aria-modal="true" aria-label="Feedback" onSubmit={submit}>
        <div className="sheet-top"><button type="button" className="close" onClick={onClose}>Close</button></div>
        <h2>What do you think so far?</h2>
        <p className="hint">Anything goes: what's confusing, what's fun, questions you'd love to see, bugs. Only the yeah/nah team reads this.</p>
        <label className="field"><span className="label">Your feedback</span>
          <textarea required minLength={2} maxLength={2000} rows={6} value={text} onChange={e => setText(e.target.value)} /></label>
        <Msg error={error} note={sent && 'Thanks, got it. Send more any time.'} />
        <button className="solid">Send feedback</button>
      </form>
    </div>
  );
}
