import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { supabase, configured, call } from './supabase.js';
import { Px } from './icons.jsx';
import { useDeckMotion } from './deckMotion.js';
import { PowerUpArt, RARITY } from './powerupArt.jsx';
import { Avatar, AvatarPicker, teamOf } from './avatars.jsx';
import Admin, { useAdminSummary } from './Admin.jsx';

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

// Answers given before signing up, kept on this device until the new profile
// claims them: { code, ids: the guest hand, answers: { id: true/false } }.
const GUEST_KEY = 'yeahnah-guest';
function loadGuest() {
  try { return JSON.parse(localStorage.getItem(GUEST_KEY)) || null; } catch { return null; }
}
function saveGuest(g) {
  try { localStorage.setItem(GUEST_KEY, JSON.stringify(g)); } catch { /* storage blocked: answers last until reload */ }
}
// Saves them to the profile once it exists. Returns how many were saved.
async function claimGuest() {
  const g = loadGuest();
  const answers = Object.entries(g?.answers || {}).map(([id, value]) => ({ question_id: Number(id), value }));
  if (!answers.length) return 0;
  const n = await call('claim_guest_answers', { p_answers: answers });
  try { localStorage.removeItem(GUEST_KEY); } catch { /* none */ }
  return n;
}

// A question link opened without an account: answer the linked question and a
// few more (5 in all), see how everyone answered, then sign up to keep them.
function GuestHand({ code, onEmpty }) {
  const [hand, setHand] = useState(null);
  const [g, setG] = useState(() => {
    const kept = loadGuest();
    return kept && kept.code === code ? kept : { code, ids: [], answers: {} };
  });
  const [i, setI] = useState(0);
  const [split, setSplit] = useState(null);
  useEffect(() => {
    call('guest_hand', { p_code: code }).then(qs => {
      if (!qs || !qs.length) return onEmpty();
      // Keep the hand dealt last time, so a reload doesn't swap the questions.
      const byId = Object.fromEntries(qs.map(q => [q.id, q]));
      const kept = g.ids.map(id => byId[id]).filter(Boolean);
      const list = kept.length === qs.length ? kept : qs;
      setHand(list);
      setG(x => ({ ...x, ids: list.map(q => q.id) }));
      const next = list.findIndex(q => !(q.id in g.answers));
      setI(next < 0 ? list.length - 1 : next);
    }).catch(onEmpty);
  }, [code]);
  useEffect(() => { if (g.ids.length) saveGuest(g); }, [g]);
  const q = hand && hand[i];
  const answered = q && q.id in g.answers;
  useEffect(() => {
    setSplit(null);
    if (answered) call('guest_split', { p_code: code, p_question: q.id }).then(setSplit).catch(() => {});
  }, [q?.id, answered]);
  if (!q) return null;
  const done = hand.filter(x => x.id in g.answers).length;
  const all = done === hand.length;
  const value = g.answers[q.id];
  const opts = q.option_yes
    ? [[true, q.emoji_yes, q.option_yes], [false, q.emoji_no, q.option_no]]
    : [[true, null, 'Yeah'], [false, null, 'Nah']];
  // The split counts everyone else; add this answer so it shows up straight away.
  const sp = split && { yes: split.yes + (value ? 1 : 0), total: split.total + 1 };
  const pct = sp ? Math.round((100 * sp.yes) / sp.total) : 0;
  return (
    <div className="card shared-q guest">
      <span className="label">{q.linked ? (q.by ? `${q.by} asked you` : 'You were asked') : `Question ${i + 1} of ${hand.length}`}
        {' · '}{done} of {hand.length} answered</span>
      <Chips q={q} />
      <h2 className="qtext">{q.text}</h2>
      {answered ? (
        <>
          <div className="inline"><span>You said</span><Pill q={q} v={value} /></div>
          {sp && (
            <div className={`split${q.option_yes ? ' pick' : ''}`} role="img" aria-label={`${pct}% ${word(q, true)}, ${100 - pct}% ${word(q, false)}`}>
              <div className="y" style={{ width: `${pct}%` }}>{pct}% {q.option_yes ? q.emoji_yes : 'yeah'}</div>
              <div className="n">{100 - pct}% {q.option_yes ? q.emoji_no : 'nah'}</div>
            </div>
          )}
          {sp && <p className="hint">{sp.total} answer{sp.total === 1 ? '' : 's'} so far, counting yours.</p>}
        </>
      ) : (
        <div className="answer-row">
          {opts.map(([v, emoji, label]) => (
            <button type="button" key={label} className={`big ${q.option_yes ? 'pick' : v ? 'yes' : 'no'}`}
              onClick={() => setG(x => ({ ...x, answers: { ...x.answers, [q.id]: v } }))}>
              {emoji && <span className="e" aria-hidden="true">{emoji}</span>}{label}
            </button>
          ))}
        </div>
      )}
      {hand.length > 1 && (
        <div className="guest-nav">
          <button type="button" className="ghost" onClick={() => setI((i + hand.length - 1) % hand.length)}><Px name="back" /> Back</button>
          <div className="dots" aria-label="Questions to answer">
            {hand.map((x, k) => <button type="button" key={x.id} className={`dot${x.id in g.answers ? ' done' : ''}`} aria-current={k === i}
              aria-label={`Question ${k + 1}`} onClick={() => setI(k)} />)}
          </div>
          <button type="button" className="ghost" onClick={() => setI((i + 1) % hand.length)}>Next <Px name="next" /></button>
        </div>
      )}
      <p className="hint">{all
        ? 'That\'s all of them. Sign up below and your answers are saved to your profile, with a fresh 5 for today on top.'
        : done
          ? 'Your answers are kept on this phone. Sign up below to save them to a profile.'
          : `Answer up to ${hand.length} before you sign up. You see how everyone answered after you vote.`}</p>
    </div>
  );
}

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
// A question a friend sends you is on the clock from the first time it's on
// your screen. Until then its challenge has the minutes they picked and no end
// time (expires_at is 'infinity'). Ones from before the 2026-10-30 database
// update have no minutes and started when they were sent.
const unseen = c => c.minutes != null && !c.seen_at;
const msLeft = (c, now) => (unseen(c) ? c.minutes * 60e3 : new Date(c.expires_at) - now);
const timeLeft = (c, now) => left(now + msLeft(c, now), now);
const minutesText = m => (m % 1440 === 0 ? `${m / 1440} day${m === 1440 ? '' : 's'}`
  : m % 60 === 0 ? `${m / 60} hour${m === 60 ? '' : 's'}` : `${m} minute${m === 1 ? '' : 's'}`);
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
  // Before the 2026-10-29 database update there's no guest hand, so the link shows as a banner.
  const [guestCode, setGuestCode] = useState(pendingQuestion());
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
      {guestCode ? <GuestHand code={guestCode} onEmpty={() => setGuestCode(null)} /> : <QuestionBanner />}
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
    const [questions, mine, follows, challenges, predictions, groups, members, config, stars, unlock, powerup, kinds, pocket, hot] = await Promise.all([
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
      supabase.from('powerup_kinds').select('kind,name,rarity,slashes,effect,keeps_days'),
      // Kept effect cards: a Wildcard keeps for 7 days, so a little over a week is enough.
      supabase.from('pocket').select('*').gte('got_at', new Date(Date.now() - 9 * 864e5).toISOString()).order('got_at'),
      // Hot ones need the 2026-10-28 database update; until it runs, there are none.
      call('hot_questions').catch(() => []),
    ]);
    // No question for today (the hourly timer may not be running): fill the day, then read the questions again.
    if (!questions.data.some(q => q.daily_date === todayUK())) {
      try { await call('ensure_daily'); questions.data = (await supabase.from('questions').select('*').order('id')).data || questions.data; }
      catch { /* before the 2026-10-26 database update; carry on without one */ }
    }
    const kindOf = Object.fromEntries((kinds.data || []).map(k => [k.kind, k]));
    const ids = new Set();
    follows.data.forEach(f => { ids.add(f.follower); ids.add(f.followed); });
    challenges.data.forEach(c => { ids.add(c.from_user); ids.add(c.to_user); });
    predictions.data.forEach(p => p.target_user && ids.add(p.target_user));
    // Groups need the 2026-10-09 database update; until it runs, show none.
    const groupRows = groups.data || [], memberRows = members.data || [];
    memberRows.forEach(m => ids.add(m.user_id));
    // Avatars need the avatars database update; without it, load people without them.
    const pick = cols => supabase.from('profiles').select(cols).in('id', [...ids]);
    let people = [];
    if (ids.size) {
      const r = await pick('id,handle,display_name,avatar');
      people = r.error ? (await pick('id,handle,display_name')).data || [] : r.data;
    }
    const person = Object.fromEntries(people.map(p => [p.id, p]));
    const iFollow = new Set(follows.data.filter(f => f.follower === me.id).map(f => f.followed));
    const followsMe = new Set(follows.data.filter(f => f.followed === me.id).map(f => f.follower));
    setD({
      me,
      cfg: Object.fromEntries((config.data || []).map(c => [c.key, c.value])),
      stars: new Set((stars.data || []).map(s => s.question_id)),
      // The most starred and answered questions lately, hottest first.
      hot: (hot || []).map(Number),
      questions: questions.data,
      byId: Object.fromEntries(questions.data.map(q => [q.id, q])),
      mine: Object.fromEntries(mine.data.map(s => [s.question_id, s])),
      person, iFollow, followsMe,
      friends: [...iFollow].filter(id => followsMe.has(id)).map(id => person[id]),
      challenges: challenges.data,
      predictions: predictions.data,
      futureUnlocked: (unlock.data || []).length > 0,
      powerup,
      kinds: kindOf,
      pocket: (pocket.data || []).filter(r => kindOf[r.kind]).map(r => ({ ...r, ...kindOf[r.kind], kind: r.kind })),
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
  const [reporting, setReporting] = useState(null);
  const [adminOpen, setAdminOpen] = useState(false);
  const [toast, setToast] = useState('');
  const now = useNow(1000);
  const meId = d && d.me && d.me.id;
  const [adminSummary, refreshAdmin] = useAdminSummary(meId);
  const adminCount = adminSummary ? adminSummary.pending + adminSummary.reports + adminSummary.feedback : 0;

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

  // Open the question from a link once the profile exists, then save the
  // answers given before signing up (after opening, so a friends' question
  // from the link can be saved too).
  const [shared, setShared] = useState(null);
  useEffect(() => {
    if (!meId) return;
    const code = pendingQuestion();
    if (code) clearQuestion();
    (async () => {
      let r = null, saved = 0;
      if (code) try { r = await call('open_question_link', { p_code: code }); } catch (e) { setToast(e.message); }
      try { saved = await claimGuest(); } catch { /* before the 2026-10-29 database update */ }
      if (!r && !saved) return;
      await reload();
      if (r) { setShared(r); setSheet(r.id); }
      if (saved) setToast(`Saved your ${saved} answer${saved === 1 ? '' : 's'} from before you signed up. You still have today's ${d?.cfg?.answers_per_day ?? 5}.`);
    })();
  }, [meId]);

  if (!d) return <div className="app" />;
  if (!d.me) return <CreateProfile onDone={reload} />;

  // Friends' questions still to answer and not run out, least time left first.
  const inbox = d.challenges.filter(c => c.to_user === d.me.id && !c.answered_at && msLeft(c, now) > 0)
    .sort((a, b) => msLeft(a, now) - msLeft(b, now));
  const ctx = { d, reload, open: setSheet, now, inbox };
  const TABS = [['today', 'today', 'Today'], ['questions', 'questions', 'Questions'], ['predict', 'predict', 'Future'], ['friends', 'group', 'Group'], ['profile', 'profile', 'Profile']];

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand"><span>yeah</span>/<em>nah</em></div>
        <div className="pills">
          <span className="pill" title="Answers left today">{d.me.answers_left_today} left</span>
          <span className="pill credits" title={`Slashes: spend ${d.cfg.send_cost ?? 2} to send a friend a question`}>{d.me.unlimited ? '∞ slashes' : `${d.me.credits} ${d.me.credits === 1 ? 'slash' : 'slashes'}`}</span>
          <button className="pill feedback" onClick={() => setFeedback(true)}>Feedback</button>
          {adminSummary && (
            <button className="pill" aria-pressed={adminOpen} onClick={() => { setAdminOpen(!adminOpen); setSheet(null); refreshAdmin(); }}>
              Admin{adminCount > 0 && ` (${adminCount})`}
            </button>
          )}
        </div>
      </header>
      {toast && <div className="note toast" role="status" onClick={() => setToast('')}>{toast}</div>}
      {adminOpen && adminSummary ? (
        <main className="screen" key="admin">
          <Admin summary={adminSummary} onChanged={() => { refreshAdmin(); reload(); }} onClose={() => setAdminOpen(false)}
            themes={[...new Set(d.questions.filter(q => q.audience !== 'friends').map(q => q.category))].sort()} />
        </main>
      ) : <main className="screen" key={tab}>
        {tab === 'today' && <Today {...ctx} />}
        {tab === 'questions' && <Questions {...ctx} />}
        {tab === 'predict' && (d.futureUnlocked ? <Predict {...ctx} /> : <FutureLocked {...ctx} />)}
        {tab === 'friends' && <Friends {...ctx} />}
        {tab === 'profile' && <Profile {...ctx} />}
      </main>}
      <nav className="nav" aria-label="Main">
        {TABS.map(([k, ico, label]) => (
          <button key={k} aria-current={!adminOpen && tab === k ? 'page' : 'false'} onClick={() => { setTab(k); setSheet(null); setAdminOpen(false); }}>
            <span className="ico"><Px name={ico} /></span>{label}
            {k === 'friends' && inbox.length > 0 && <span className="badge">{inbox.length}</span>}
          </button>
        ))}
      </nav>
      {feedback && <FeedbackSheet tab={tab} onClose={() => setFeedback(false)} />}
      {reporting && <ReportSheet q={reporting} onClose={() => setReporting(null)} />}
      {sheet && d.byId[sheet] && (
        <div className="scrim" onClick={e => e.target === e.currentTarget && setSheet(null)}>
          <div className="sheet" role="dialog" aria-modal="true">
            <div className="sheet-top" style={{ gap: 8 }}>
              {d.byId[sheet].created_by !== d.me.id && !d.byId[sheet].is_event
                && <button className="close" onClick={() => { setReporting(d.byId[sheet]); setSheet(null); }}>Report</button>}
              <button className="close" onClick={() => setSheet(null)}>Close</button>
            </div>
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
  async function follow(on) {
    setError('');
    const { error: e } = on
      ? await supabase.from('follows').insert({ follower: d.me.id, followed: shared.by_id })
      : await supabase.from('follows').delete().eq('follower', d.me.id).eq('followed', shared.by_id);
    if (e) setError(e.message); else setShared({ ...shared, following: on, requested: false, undone: !on });
  }
  // Opening the link sends the writer a friend request (they see you under Follow back), with an undo.
  return (
    <div className="hook shared-by">
      {shared.by} shared this with you.{' '}
      {shared.friends ? null : shared.requested && shared.following
        ? <>We've sent {shared.by} a friend request, so you'll be friends once they follow you back.{' '}
            <button className="linkbtn" onClick={() => follow(false)}>Undo</button></>
        : shared.following
        ? `Friend request sent. You'll be friends once ${shared.by} adds you back.`
        : shared.undone
        ? <>Friend request taken back. <button className="linkbtn" onClick={() => follow(true)}>Add {shared.by} as a friend</button></>
        : <button className="linkbtn" onClick={() => follow(true)}>Add {shared.by} as a friend</button>}
      <Msg error={error} />
    </div>
  );
}

// A link to a question you wrote. Anyone who opens it can answer, signing up first if they need to.
// A question's link (your own one, so whoever opens it sees it came from you):
// the phone's share menu where there is one, otherwise copied.
function useShareLink(q) {
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
  return { url, note, error, share };
}
// Anyone can share an everyday question; a question for friends only by whoever wrote it.
const linkable = (q, d) => q.created_by === d.me.id || (q.audience !== 'friends' && !q.is_event && q.sensitivity !== 'sensitive');

function ShareLink({ q }) {
  const { url, note, error, share } = useShareLink(q);
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

function QuestionCard({ q, small, deck, onScreen = true, noAnswers, d, reload, now, inbox, open }) {
  const mine = d.mine[q.id];
  const [vis, setVis] = useState(() => startingVisibility(q, d));
  const [split, setSplit] = useState(null);
  const [friendAns, setFriendAns] = useState([]);
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [sending, setSending] = useState(false);
  const challenge = inbox.find(c => c.question_id === q.id);
  const sentBy = d.challenges.find(c => c.to_user === d.me.id && c.question_id === q.id);
  // A friend's timer starts once this card is on screen with the app open.
  const waiting = inbox.some(c => c.question_id === q.id && unseen(c));
  useEffect(() => {
    if (!onScreen || !waiting) return;
    const see = () => {
      if (document.hidden) return;
      document.removeEventListener('visibilitychange', see);
      call('see_question', { p_question: q.id }).then(reload).catch(() => {});
    };
    document.addEventListener('visibilitychange', see);
    see();
    return () => document.removeEventListener('visibilitychange', see);
  }, [onScreen, waiting, q.id]);

  // Peek and Mind reader show these before you answer.
  const peeked = !!usedOn(d, 'peek', q.id), read = !!usedOn(d, 'mind_reader', q.id);
  useEffect(() => {
    setError(''); setNote('');
    if (mine || peeked) call('question_split', { p_question: q.id }).then(setSplit).catch(() => {});
    else setSplit(null);
    if (mine || read) call('friends_answers', { p_question: q.id }).then(setFriendAns).catch(() => {});
    else setFriendAns([]);
  }, [q.id, mine?.id, peeked, read]);
  const called = mine && usedOn(d, 'called_it', q.id);

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
        <CardPowers q={q} d={d} reload={reload} challenge={challenge} split={split} friendAns={friendAns} />
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
          <span>{mine.source === 'app' || mine.source === 'link' ? 'You said' : `${mine.source} says`}</span><Pill q={q} v={mine.value} />
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
        {called && called.won != null && (
          <div className="hook">{called.won
            ? `Called it! ${called.result}% of everyone else said yeah and you guessed ${called.guess}%. +${called.won} slashes.`
            : `Not this time: ${called.result}% of everyone else said yeah, and you guessed ${called.guess}%.`}</div>
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
              Change my answer to {word(q, !mine.value).toLowerCase()} ({d.me.changes_left_today > 1 || inPocket(d, 'second_thoughts').length ? `${d.me.changes_left_today === 1 ? '1 change' : `${d.me.changes_left_today} changes`} left today` : '1 a day'})</button>
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
        {d.hot.includes(q.id) && <span className="chip hot"><Px name="Hot ones" scale={1} /> Hot</span>}
        {starrable(q) && (deck ? d.stars.has(q.id) : !mine || d.stars.has(q.id)) && <StarToggle q={q} d={d} reload={reload} chip />}
        {sentBy ? <span className="chip friend">From {d.person[sentBy.from_user]?.display_name || 'a friend'}</span>
          : q.audience === 'friends' && <span className="chip friend">{q.created_by === d.me.id ? 'Your question'
            : d.person[q.created_by] ? `By ${d.person[q.created_by].display_name}` : 'Shared with you'}</span>}
        {challenge && <span className="chip timer"><Px name="timer" scale={1} /> {timeLeft(challenge, now)}</span>}
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
  // Free post makes the next paid send free, and the same question to anyone else in the next few minutes.
  const recent = usedOn(d, 'free_post', q.id);
  const freePost = q.audience !== 'friends' && (inPocket(d, 'free_post').length > 0
    || (recent && Date.now() - new Date(recent.used_at) < (d.cfg.free_post_minutes ?? 5) * 60e3));
  const cost = q.audience === 'friends' || freePost ? 0 : d.cfg.send_cost ?? 2;
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
  const link = useShareLink(q);

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
      <div className="send-head">
        <span className="label">Send to friends: {cost ? `${cost} slashes each` : freePost ? 'free with your Free post' : 'free for a friend question'}. They get {d.cfg.challenge_reward ?? 2} if they answer in time.</span>
        <button className="linkbtn" onClick={onClose}>Close</button>
      </div>
      <FriendPicker d={d} picked={picked} setPicked={setPicked} blocked={blocked} />
      <div className="seg" role="group" aria-label="Timer">
        {TIMERS.map(([m, l]) => <button key={m} aria-pressed={timer === m} onClick={() => setTimer(m)}>{l}</button>)}
      </div>
      <div className="inline">
        <button className="solid" disabled={!picked.length || busy || total > d.me.credits} onClick={send}>
          {busy ? 'Sending…' : picked.length ? `Send to ${picked.length} · ${total ? `${total} slashes` : 'free'}` : 'Pick who gets it'}
        </button>
        {linkable(q, d) && <button className="ghost link-btn" onClick={link.share}>Link</button>}
      </div>
      {link.url && <input className="link-url" readOnly value={link.url} onFocus={e => e.target.select()} aria-label="Link to this question" />}
      <Msg error={link.error} note={link.note} />
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

// Puts each id at a random spot among the next few cards after `from`.
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
  // Questions friends wrote come first, then starred ones, then hot ones
  // (hottest first), then the rest.
  const hot = id => d.hot.indexOf(id);
  const rank = q => (q.audience === 'friends' ? 0 : d.stars.has(q.id) ? 1 : hot(q.id) >= 0 ? 2 : 3);
  return [0, 1, 2, 3].flatMap(r => qs.filter(q => rank(q) === r)
    .sort((a, b) => (r === 2 ? hot(a.id) - hot(b.id) : 0)).map(q => q.id));
}

// Power-ups: some days the first hand has one in it. For now each one holds
// slashes to claim; rarer ones hold more. It's a card in the hand like any
// other, under the id PU, and stays there once claimed.
const PU = 'powerup';
const ukDate = t => new Date(t).toLocaleDateString('en-CA', { timeZone: 'Europe/London' });

// What each effect card does, and how it's used.
function effectText(effect, cfg) {
  const n = cfg.extra_hand_cards ?? 3;
  return {
    second_thoughts: ['One extra change of mind today, on top of your usual one.', 'It works by itself the next time you change an answer.'],
    free_post: ['Your next send costs nothing, even to a whole group.', 'It works by itself on your next send that would cost slashes.'],
    peek: ['See the crowd split on one question before you answer it.', 'Tap Peek on a card you haven\'t answered.'],
    overtime: [`An extra ${cfg.overtime_minutes ?? 60} minutes on a question a friend sent you, so you can still earn the slashes.`, 'Tap Overtime on a friend\'s card with a timer.'],
    mind_reader: ['See how your friends answered one question before you answer it.', 'Tap Mind reader on a card you haven\'t answered.'],
    extra_hand: [`${n} more cards today, and ${n} more answers to go with them.`, 'They\'re dealt into your hand straight away.'],
    called_it: [`Guess how many say yeah to today's question before you vote. Within ${cfg.called_it_window ?? 5} points of everyone else wins ${cfg.called_it_prize ?? 10} slashes.`,
      'Make your guess on today\'s question card. A miss costs nothing.'],
    wildcard: ['Turns into any other card you like.', 'Tap what it becomes on this card.'],
  }[effect] || ['', ''];
}
// Effect cards still in your pocket, and the one used on a question.
const inPocket = (d, effect) => d.pocket.filter(r => r.effect === effect && !r.used_at && r.expires_on >= todayUK());
const usedOn = (d, effect, qid) => d.pocket.find(r => r.effect === effect && r.used_at && r.question_id === qid);
function PowerUpCard({ p, d, reload }) {
  const [error, setError] = useState('');
  const [note, setNote] = useState('');
  const [busy, setBusy] = useState(false);
  const level = RARITY.indexOf(p.rarity) + 1;
  const unit = p.slashes === 1 ? 'slash' : 'slashes';
  const [does, how] = effectText(p.effect, d.cfg);
  const deal = p.effect === 'extra_hand';
  const wild = p.effect === 'wildcard';
  // A Wildcard is picked right here: before it's claimed, or while one kept earlier is still unused.
  const pick = wild && (!p.claimed || inPocket(d, 'wildcard').length > 0);
  async function claim() {
    setError(''); setBusy(true);
    try { await call('claim_powerup'); await reload(); } catch (e) { setError(e.message); }
    setBusy(false);
  }
  async function become(kind) {
    setError(''); setNote(''); setBusy(true);
    try {
      if (!p.claimed) await call('claim_powerup');
      const r = await call('use_power', { p_kind: 'wildcard', p_pick: kind });
      setNote(`Your Wildcard became ${r.name}. ${r.effect ? effectText(r.effect, d.cfg)[1] : `${r.slashes} slashes added.`}`);
    } catch (e) { setError(e.message); }
    await reload();
    setBusy(false);
  }
  let action, after;
  if (!p.effect) {
    action = `Claim ${p.slashes} ${unit}`;
    after = `Claimed. ${p.slashes} ${unit} added.`;
  } else if (deal) {
    action = `Deal ${d.cfg.extra_hand_cards ?? 3} more cards`;
    after = 'Dealt. Swipe on to play them.';
  } else if (wild) {
    after = 'Played.';
  } else {
    action = 'Keep it';
    after = 'Kept.';
  }
  return (
    <div className={`card deck-card powerup ${p.rarity} ${p.kind}${p.claimed ? ' claimed' : ''}`}>
      <div className="chips">
        <span className="chip rarity">{p.rarity}</span>
        <span className="pips" role="img" aria-label={`Rarity ${level} of 5`}>
          {RARITY.map((r, k) => <i key={r} className={k < level ? 'on' : ''} />)}
        </span>
        <span className="chip">{p.effect ? 'Effect' : 'Power-up'}</span>
      </div>
      <PowerUpArt p={p} />
      <h2 className="qtext">{p.name}</h2>
      <p className="hint">{p.blurb}</p>
      {p.effect && <p className="fx">{does}</p>}
      {pick ? (
        <div className="pu-pick">
          <span className="label">Turn it into</span>
          <div className="chips">
            {Object.values(d.kinds).filter(x => x.effect !== 'wildcard').map(x => (
              <button key={x.kind} className={`chip pocket-chip powerup ${x.rarity}`} onClick={() => become(x.kind)} disabled={busy}>{x.name}</button>
            ))}
          </div>
        </div>
      ) : p.claimed
        ? <p className="pu-done"><Px name="check" /> {after}</p>
        : <button className="solid pu-claim" onClick={claim} disabled={busy}>{action}</button>}
      {!note && (
        <p className="hint">
          {p.effect && !deal && !wild ? `${how} ` : ''}
          {p.claimed
            ? (pick ? 'Use it by midnight.'
              : p.effect && !deal && !wild ? (p.keeps_days > 1 ? `Keeps for ${p.keeps_days} days.` : 'Use it by midnight.')
              : 'Another power-up could turn up in a future first hand.')
            : `${p.odds ? `${p.odds}% of power-ups are ${p.name}. ` : ''}Gone at midnight if you don't ${deal || wild ? 'use' : p.effect ? 'keep' : 'claim'} it.`}
        </p>
      )}
      <Msg error={error} note={note} />
    </div>
  );
}

// Effect cards used on a question card: Peek, Mind reader, Overtime and Called it.
function CardPowers({ q, d, reload, challenge, split, friendAns }) {
  const [error, setError] = useState('');
  const [guess, setGuess] = useState(50);
  const today = q.daily_date === todayUK();
  const peeked = usedOn(d, 'peek', q.id), read = usedOn(d, 'mind_reader', q.id), called = usedOn(d, 'called_it', q.id);
  async function use(kind, extra) {
    setError('');
    try { await call('use_power', { p_kind: kind, p_question: q.id, ...extra }); await reload(); } catch (e) { setError(e.message); }
  }
  const buttons = [
    !peeked && inPocket(d, 'peek').length > 0 && ['peek', 'Peek at the split'],
    !read && inPocket(d, 'mind_reader').length > 0 && d.friends.length > 0 && ['mind_reader', 'Mind reader: friends\' answers'],
    challenge && inPocket(d, 'overtime').length > 0 && ['overtime', `Overtime: +${d.cfg.overtime_minutes ?? 60} min`],
  ].filter(Boolean);
  const pct = split && split.total ? Math.round((100 * split.yes) / split.total) : 0;
  const canCall = today && !called && inPocket(d, 'called_it').length > 0;
  if (!buttons.length && !peeked && !read && !called && !canCall) return null;
  return (
    <div className="powers">
      {peeked && split && (
        <p className="hint"><strong>Peek:</strong> {split.total ? `${pct}% ${q.option_yes ? q.option_yes : 'yeah'}, ${100 - pct}% ${q.option_yes ? q.option_no : 'nah'}, from ${split.total} answer${split.total === 1 ? '' : 's'}.` : 'Nobody has answered yet.'}</p>
      )}
      {read && (
        <p className="hint"><strong>Mind reader:</strong> {friendAns.length ? friendAns.map(f => `${f.display_name}: ${word(q, f.value)}`).join(', ') : 'None of your friends has answered yet.'}</p>
      )}
      {called && <p className="hint"><strong>Called it:</strong> you guessed {called.guess}% say yeah. Answer to see if you called it.</p>}
      {canCall && (
        <div className="guess">
          <label className="label" htmlFor={`guess-${q.id}`}>Called it: what % say yeah?</label>
          <div className="inline">
            <input id={`guess-${q.id}`} type="range" min="0" max="100" value={guess} onChange={e => setGuess(+e.target.value)} />
            <span className="n">{guess}%</span>
            <button className="ghost" onClick={() => use('called_it', { p_guess: guess })}>Lock in</button>
          </div>
        </div>
      )}
      {buttons.length > 0 && (
        <div className="chips">
          {buttons.map(([kind, label]) => (
            <button key={kind} className={`chip pocket-chip powerup ${d.kinds[kind]?.rarity}`} onClick={() => use(kind)}>{label}</button>
          ))}
        </div>
      )}
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
  const extraToday = d.pocket.filter(r => r.effect === 'extra_hand' && r.used_at && ukDate(r.used_at) === today).length;
  // Five cards a day: today's question first, then what you've answered today,
  // then enough you haven't answered to make five, in a shuffled order.
  // Questions friends send you are extra cards on top.
  const [hand, setHand] = useState(() => {
    const kept = loadHand(uid, today);
    if (kept && Array.isArray(kept.ids)) {
      const ids = kept.ids.filter(id => (id === PU ? d.powerup : d.byId[id]));
      return { ids, i: Math.min(kept.i || 0, Math.max(ids.length - 1, 0)), seen: kept.seen || ids, extra: kept.extra || 0 };
    }
    const first = daily ? [daily.id] : [];
    const done = answeredToday.filter(id => !first.includes(id));
    // Enough to make five, or as many answers as you have left today if that's more.
    const left = daily ? d.me.other_answers_left_today : d.me.answers_left_today;
    const fresh = dealable(d, today, new Set([...first, ...done, ...inboxIds])).slice(0, Math.max(size - first.length - done.length, left, 0));
    const ids = [...first, ...done, ...fresh];
    // Today's power-up, if there is one, goes somewhere after the first card you haven't answered.
    if (d.powerup) ids.splice(first.length + done.length + 1 + Math.floor(Math.random() * fresh.length), 0, PU);
    return { ids, i: Math.max(ids.findIndex(id => !d.mine[id]), 0), seen: ids, extra: extraToday };
  });
  // A daily question set after this hand was dealt becomes the next card.
  useEffect(() => {
    if (daily && !hand.ids.includes(daily.id)) {
      setHand(h => h.ids.includes(daily.id) ? h : { ...h, ids: [...h.ids.slice(0, h.i), daily.id, ...h.ids.slice(h.i)], seen: [...h.seen, daily.id] });
    }
  }, [daily?.id]);
  // Extra hand: more cards right after the one you're on.
  useEffect(() => {
    setHand(h => {
      if (extraToday <= (h.extra || 0)) return h;
      const n = (d.cfg.extra_hand_cards ?? 3) * (extraToday - (h.extra || 0));
      const fresh = [...new Set([...dealable(d, today, new Set([...h.ids, ...h.seen])), ...dealable(d, today, new Set(h.ids))])].slice(0, n);
      const ids = [...h.ids];
      ids.splice(h.i + 1, 0, ...fresh);
      return { ...h, ids, extra: extraToday, seen: [...new Set([...h.seen, ...fresh])] };
    });
  }, [extraToday]);
  // Something answered outside the stack today (in Questions, or on another device) joins it at the end.
  useEffect(() => {
    setHand(h => {
      const missing = answeredToday.filter(id => !h.ids.includes(id));
      return missing.length ? { ...h, ids: [...h.ids, ...missing], seen: [...new Set([...h.seen, ...missing])] } : h;
    });
  }, [answeredToday.join()]);
  // Questions friends send you come up next, right after the card on top, least
  // time left first (one you haven't seen yet counts as its whole time). When more
  // arrive, the ones still to come are put back in that order with them.
  useEffect(() => {
    setHand(h => {
      const fresh = inboxIds.filter(id => d.byId[id] && !h.ids.includes(id));
      if (!fresh.length) return h;
      const top = h.ids[h.i];
      const coming = new Set(h.ids.filter(id => id !== top && inboxIds.includes(id) && !d.mine[id]));
      const keep = h.ids.filter(id => !coming.has(id));
      const at = keep.indexOf(top) + 1;
      // inboxIds is already least time left first.
      const sent = inboxIds.filter(id => coming.has(id) || fresh.includes(id));
      return { ...h, ids: [...keep.slice(0, at), ...sent, ...keep.slice(at)], i: Math.max(at - 1, 0), seen: [...h.seen, ...fresh] };
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
  // Cards come up in this order: today's question, questions friends sent you
  // (least time left first), questions friends wrote (free, so they're extra
  // cards), starred ones, hot ones, then the rest.
  // Questions starred since the hand was dealt take the place of the next other
  // unanswered cards, never the card on top.
  const friendQs = d.questions.filter(x => x.audience === 'friends' && !d.mine[x.id]).map(x => x.id);
  useEffect(() => {
    setHand(h => {
      const friends = dealable(d, today, new Set([...h.ids, ...h.seen])).filter(byFriend);
      const starred = dealable(d, today, new Set(h.ids)).filter(id => d.stars.has(id) && !byFriend(id));
      if (!friends.length && !starred.length) return h;
      const ids = [...h.ids];
      // After any friends' questions on a timer that are next up.
      let at = Math.min(h.i + 1, ids.length);
      while (at < ids.length && inboxIds.includes(ids[at]) && !d.mine[ids[at]]) at++;
      ids.splice(at, 0, ...friends);
      for (let s = 1; s < ids.length && starred.length; s++) {
        const k = (h.i + s) % ids.length;
        if (canSwap(ids[k]) && !byFriend(ids[k])) ids[k] = starred.shift();
      }
      return ids.join() === h.ids.join() ? h : { ...h, ids, seen: [...new Set([...h.seen, ...ids])] };
    });
  }, [[...d.stars].join(), friendQs.join()]);
  // The hand never holds more cards that use up an answer than you have answers
  // left: starred ones are kept first, then hot ones, and the others come back another
  // day. Once your answers are gone, what's left is what you've answered and
  // what's free (today's question, and questions friends wrote or sent you).
  const answersLeft = Math.max(d.me.other_answers_left_today, 0);
  const paid = id => id !== PU && d.byId[id] && !d.mine[id] && !counts(id);
  useEffect(() => {
    setHand(h => {
      const cards = h.ids.filter(paid);
      if (cards.length <= answersLeft) return h;
      const order = id => (d.stars.has(id) ? 0 : d.hot.includes(id) ? 1 : 2);
      const keep = new Set([0, 1, 2].flatMap(r => cards.filter(id => order(id) === r)).slice(0, answersLeft));
      const ids = h.ids.filter(id => !paid(id) || keep.has(id));
      // Stay on the same card, or the next one still in the hand.
      let k = h.i;
      while (k < h.ids.length && !ids.includes(h.ids[k])) k++;
      const i = k < h.ids.length ? ids.indexOf(h.ids[k]) : 0;
      return { ...h, ids, i: Math.max(0, Math.min(i, ids.length - 1)) };
    });
  }, [answersLeft, hand.ids.join(), Object.keys(d.mine).length, [...d.stars].join()]);
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
              {id === PU ? <PowerUpCard p={d.powerup} d={d} reload={ctx.reload} />
                : <QuestionCard q={d.byId[id]} deck onScreen={slots[id] === 0} noAnswers={!d.mine[id] && !counts(id) && d.me.other_answers_left_today <= 0} {...ctx} />}
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
            {answersLeft > 0 && <button className="ghost" onClick={reshuffle} disabled={!swappable.length}><Px name="shuffle" /> Shuffle</button>}
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

const HOT = 'Hot ones';

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
  // Hot ones: the most starred and answered lately, a theme of their own on top
  // of the one each question is in.
  const hotQs = d.hot.filter(id => d.byId[id] && qs.includes(d.byId[id]));
  const hotTheme = { name: HOT, total: hotQs.length, done: hotQs.filter(id => d.mine[id]).length };
  const tiles = hotQs.length ? [hotTheme, ...themes] : themes;
  const inTheme = q => (theme === HOT ? hotQs.includes(q.id) : q.category === theme);
  const list = qs.filter(q => (!theme || inTheme(q))
    && (filter === 'all' || (filter === 'open' ? !d.mine[q.id] : filter === 'starred' ? d.stars.has(q.id)
      : filter === 'sent' ? sent.has(q.id) : q.sensitivity === filter)))
    .sort((a, b) => (theme === HOT ? hotQs.indexOf(a.id) - hotQs.indexOf(b.id) : 0));
  const starredOpen = qs.filter(q => d.stars.has(q.id) && !d.mine[q.id]).length;
  const picked = theme === HOT ? hotTheme : byTheme[theme];
  return (
    <>
      <MakeQuestion {...ctx} themes={themes.map(t => t.name).filter(n => n !== 'Friends')} />
      <div className="themes" role="group" aria-label="Themes">
        {tiles.map(t => (
          <button key={t.name} className={`theme${t.name === HOT ? ' hot' : ''}`} aria-pressed={theme === t.name} onClick={() => setTheme(theme === t.name ? null : t.name)}>
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
          ? <>{picked.name}: {picked.done} of {picked.total} answered · showing {list.length} · <button className="linkbtn" onClick={() => setTheme(null)}>All themes</button>
            {theme === HOT && <><br />The most starred and answered questions in the last {d.cfg.hot_days ?? 7} days, hottest first. They're dealt into Today after your starred ones.</>}</>
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
            <Need ok={enough}>{cost} slashes, once. You have {d.me.unlimited ? 'unlimited slashes' : d.me.credits}.</Need>
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
  const [viewing, setViewing] = useState(null);
  const meId = d.me.id;
  const friendIds = d.friends.filter(Boolean).map(f => f.id);
  const answers = useAnswersOf(friendIds);

  // A profile replaces the list; Back returns to it at the top.
  function view(p) {
    setViewing(p);
    document.querySelector('.screen')?.scrollTo(0, 0);
  }
  if (viewing) return <PersonProfile d={d} who={viewing} open={open} onBack={() => view(null)} />;

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
      <Groups d={d} reload={reload} open={open} view={view} />
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
          <button className="linkbtn" onClick={async () => {
            const id = card.id || (await supabase.from('profiles').select('id').eq('handle', card.handle).single()).data?.id;
            if (id) view({ id, handle: card.handle, display_name: card.display_name });
          }}>See their answers</button>
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
              <span className="chip timer"><Px name="timer" scale={1} /> {timeLeft(c, now)}</span>
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
        <div className="rows">
          {d.friends.filter(Boolean).map(f => {
            const a = answers && similarity(d, answers[f.id] || []);
            return (
              <button className="row person-row" key={f.id} onClick={() => view(f)}>
                <span className="who"><Avatar value={f.avatar} px={32} /><span>{f.display_name} <span className="hint">@{f.handle}</span></span></span>
                <span className="agree">{!a ? '' : a.both > 0
                  ? <><b>{a.pct}%</b> <span className="hint">alike on {a.both}</span></>
                  : <span className="hint">nothing in common yet</span>} <Px name="next" scale={1} /></span>
              </button>
            );
          })}
        </div>
        {waiting.map(p => <p className="hint" key={p.id}>Waiting for {p.display_name} to follow back.</p>)}
      </div>
      <SentByMe d={d} now={now} />
    </>
  );
}

// Other people's current answers, as many as each has let you see: the
// "read statements" policy only returns public ones, plus friends-only ones
// to friends, and never private ones.
function useAnswersOf(ids) {
  const [rows, setRows] = useState(null);
  const key = ids.join();
  useEffect(() => {
    if (!ids.length) return setRows({});
    let live = true;
    supabase.from('statements').select('user_id,question_id,value,visibility,created_at')
      .in('user_id', ids).is('superseded_at', null).order('created_at', { ascending: false })
      .then(({ data }) => {
        if (!live) return;
        const by = {};
        (data || []).forEach(s => (by[s.user_id] = by[s.user_id] || []).push(s));
        setRows(by);
      });
    return () => { live = false; };
  }, [key]);
  return rows;
}

// How alike you are: of the questions you've both answered (where you can see
// their answer), the share where you picked the same side.
function similarity(d, theirs) {
  const both = theirs.filter(s => d.mine[s.question_id] && d.byId[s.question_id]);
  const agree = both.filter(s => d.mine[s.question_id].value === s.value).length;
  return { both: both.length, agree, pct: both.length ? Math.round((100 * agree) / both.length) : null };
}

// Someone's profile: what they answered that you can see, side by side with
// yours, and how alike the two of you are. Their answer to a question you
// haven't answered stays hidden until you do, as everywhere else.
function PersonProfile({ d, who, open, onBack }) {
  const [card, setCard] = useState(null);
  const [show, setShow] = useState('all');
  const theirs = useAnswersOf([who.id]);
  useEffect(() => { call('profile_card', { p_handle: who.handle }).then(setCard).catch(() => {}); }, [who.handle]);

  const name = who.display_name;
  const visible = theirs ? (theirs[who.id] || []).filter(s => d.byId[s.question_id]) : null;
  const sim = similarity(d, visible || []);
  const isFriend = card ? card.is_friend : d.friends.some(f => f && f.id === who.id);

  // Alike per theme, where you share at least two answers.
  const themes = {};
  (visible || []).forEach(s => {
    const mine = d.mine[s.question_id];
    if (!mine) return;
    const t = (themes[d.byId[s.question_id].category] ||= { both: 0, agree: 0 });
    t.both += 1; if (mine.value === s.value) t.agree += 1;
  });
  const byTheme = Object.entries(themes).filter(([, t]) => t.both >= 2)
    .map(([c, t]) => ({ c, pct: Math.round((100 * t.agree) / t.both), both: t.both }))
    .sort((a, b) => b.pct - a.pct || b.both - a.both);

  const kind = s => (!d.mine[s.question_id] ? 'locked' : d.mine[s.question_id].value === s.value ? 'same' : 'diff');
  const counts = { all: 0, same: 0, diff: 0, locked: 0 };
  (visible || []).forEach(s => { counts.all += 1; counts[kind(s)] += 1; });
  const list = (visible || []).filter(s => show === 'all' || kind(s) === show)
    .sort((a, b) => (kind(a) === 'locked') - (kind(b) === 'locked'));
  const FILTERS = [['all', 'All'], ['same', 'Same'], ['diff', 'Different'], ['locked', 'Not answered yet']];

  return (
    <>
      <button className="linkbtn back" onClick={onBack}><Px name="back" scale={1} /> Group</button>
      <div className="head me-head">
        <Avatar value={card ? card.avatar : who.avatar} px={64} />
        <div>
        <h1>{name}</h1>
        <span className="hint">@{who.handle}{teamOf(card ? card.avatar : who.avatar) ? ` · Team ${teamOf(card ? card.avatar : who.avatar)}` : ''} · {isFriend ? 'Friends' : card?.follows_me ? 'Follows you' : card?.i_follow ? 'Waiting for them to follow back' : 'Not connected'}</span>
        </div>
      </div>
      <div className="stats">
        <div className="stat"><b>{sim.pct ?? '–'}{sim.pct != null && '%'}</b><span>{sim.both ? `alike on ${sim.both}` : 'alike'}</span></div>
        <div className="stat"><b>{visible ? visible.length : '–'}</b><span>answers you can see</span></div>
        <div className="stat"><b>{card?.predictions?.rate ?? '–'}{card?.predictions?.rate != null && '%'}</b><span>hit rate</span></div>
      </div>
      {sim.both > 0 && (
        <p className="hint" style={{ marginTop: 8 }}>
          You picked the same side as {name} on {sim.agree} of the {sim.both} {sim.both === 1 ? 'question' : 'questions'} you've both answered.
        </p>
      )}
      {byTheme.length > 0 && (
        <div className="section"><h2>Where you line up</h2>
          <div className="chips">{byTheme.map(t => (
            <span key={t.c} className="chip"><Px name={t.c} scale={1} /> {t.c} {t.pct}%</span>
          ))}</div>
        </div>
      )}

      <div className="section"><h2>{name}'s answers</h2>
        {visible && visible.length > 0 && (
          <div className="filters" role="group" aria-label="Show">
            {FILTERS.filter(([k]) => k === 'all' || counts[k] > 0).map(([k, label]) => (
              <button key={k} aria-pressed={show === k} onClick={() => setShow(k)}>{label} {counts[k]}</button>
            ))}
          </div>
        )}
        {visible === null && <p className="empty">Loading…</p>}
        {visible && visible.length === 0 && (
          <p className="empty">{name} hasn't shared any answers with you yet.</p>
        )}
        <div className="rows">
          {list.map(s => {
            const q = d.byId[s.question_id], mine = d.mine[s.question_id], k = kind(s);
            return (
              <button key={s.question_id} className="row" onClick={() => open(q.id)}>
                <span>
                  <span className="t">{q.text}</span>
                  {k === 'locked'
                    ? <span className="hint">Answer it to see what {name} said.</span>
                    : <span className="chips">
                        <span className={`vpill ${pillClass(q, s.value)}`}>{name}: {word(q, s.value)}</span>
                        <span className={`vpill ${pillClass(q, mine.value)}`}>You: {word(q, mine.value)}</span>
                      </span>}
                </span>
                <span>{k === 'locked' ? <Px name="lock" label="Locked" /> : k === 'same' ? <Px name="check" label="Same" /> : <Px name="cross" label="Different" />}</span>
              </button>
            );
          })}
        </div>
        <p className="hint" style={{ marginTop: 8 }}>
          {isFriend
            ? `You see the answers ${name} shows to friends or everyone. Private answers never show here.`
            : `You only see answers ${name} made public. Once you're friends you'll see their friends-only answers too.`}
        </p>
      </div>
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
          c.answered_at ? 'answered in time'
            : unseen(c) ? `not seen yet, then ${minutesText(c.minutes)} to answer`
            : msLeft(c, now) > 0 ? <><Px name="timer" scale={1} /> {timeLeft(c, now)}</> : 'ran out of time'}</p>
      ))}
    </div>
  );
}

function Profile({ d, reload }) {
  const [error, setError] = useState('');
  const [picking, setPicking] = useState(false);
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
      <div className="head me-head">
        <button className="av-btn" onClick={() => setPicking(!picking)} aria-label="Change your avatar"><Avatar value={d.me.avatar} px={64} /></button>
        <div>
          <h1>{d.me.display_name}</h1>
          <span className="hint">@{d.me.handle}{teamOf(d.me.avatar) ? ` · Team ${teamOf(d.me.avatar)}` : ''}{d.me.is_adult ? '' : ' · Friends-only profile'}</span>
          <button className="linkbtn" onClick={() => setPicking(!picking)}>{d.me.avatar ? 'Change avatar or team' : 'Pick your avatar and team'}</button>
        </div>
      </div>
      {picking && <AvatarPicker value={d.me.avatar} onCancel={() => setPicking(false)}
        onSave={async v => { await act('set_avatar', { p_avatar: v }); setPicking(false); }} />}
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

function Groups({ d, reload, open, view }) {
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
      <div className="chips">{people.map(p => p.id === d.me.id
        ? <span key={p.id} className="chip">You</span>
        : <button key={p.id} className="chip" onClick={() => view(p)}>{p.display_name}</button>)}</div>
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

// Report a question: it goes to the admin inbox with the question attached.
function ReportSheet({ q, onClose }) {
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);
  async function submit(e) {
    e.preventDefault(); setError('');
    try { await call('report', { p_reason: text.trim(), p_question: q.id }); setSent(true); }
    catch (err) { setError(err.message); }
  }
  return (
    <div className="scrim" onClick={e => e.target === e.currentTarget && onClose()}>
      <form className="sheet" role="dialog" aria-modal="true" aria-label="Report a question" onSubmit={submit}>
        <div className="sheet-top"><button type="button" className="close" onClick={onClose}>Close</button></div>
        <h2>Report this question</h2>
        <p className="hint">"{q.text}"</p>
        <p className="hint">Tell us what's wrong: offensive, unfair, a duplicate, badly worded. Only the yeah/nah team sees this, along with the question.</p>
        {!sent && <label className="field"><span className="label">What's wrong with it</span>
          <textarea required minLength={3} maxLength={500} rows={4} value={text} onChange={e => setText(e.target.value)} /></label>}
        <Msg error={error} note={sent && 'Thanks, we\'ll take a look.'} />
        {!sent && <button className="solid">Send report</button>}
      </form>
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
