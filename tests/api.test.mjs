// End-to-end checks of the yeah/nah backend through the same API the app uses.
//
// Run against a fresh database (migration + seed) on a local Supabase or a
// throwaway project with "Confirm email" turned off:
//   SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_KEY=... npm test
// It creates test users. Never point it at a project with real people in it.

import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { createClient } from '@supabase/supabase-js';

const URL = process.env.SUPABASE_URL;
const ANON = process.env.SUPABASE_ANON_KEY;
const SERVICE = process.env.SUPABASE_SERVICE_KEY;
const run = Date.now().toString(36);
const opts = { auth: { persistSession: false, autoRefreshToken: false } };
const admin = createClient(URL, SERVICE, opts);

async function user(name, birth) {
  const c = createClient(URL, ANON, opts);
  const { error } = await c.auth.signUp({ email: `${name}.${run}@example.com`, password: 'demo-password-123' });
  assert.ifError(error);
  if (birth) await ok(c.rpc('create_profile', { p_handle: `${name}_${run}`, p_display_name: name, p_birth_date: birth }));
  c.handle = `${name}_${run}`;
  return c;
}
async function ok(p) { const { data, error } = await p; assert.ifError(error); return data; }
async function fails(p, re) {
  const { error } = await p;
  assert.ok(error, 'expected an error');
  if (re) assert.match(error.message, re);
}
const me = c => ok(c.rpc('my_profile'));
const qid = async (c, text) => (await ok(c.from('questions').select('id').eq('text', text).single())).id;

let alice, bob, tia, daily, others;

const yearsAgo = n => new Date(Date.now() - n * 365.25 * 864e5).toISOString().slice(0, 10);
const setMinAge = n => ok(admin.from('app_config').update({ value: n }).eq('key', 'min_age'));
const setDefaultPublic = n => ok(admin.from('app_config').update({ value: n }).eq('key', 'new_answers_public'));
after(() => Promise.all([setMinAge(18), setDefaultPublic(1)]));

test('sign-up is 18+ for now', async () => {
  const kid = await user('kid17');
  await fails(kid.rpc('create_profile', { p_handle: `kid17_${run}`, p_display_name: 'kid', p_birth_date: yearsAgo(17) }), /18 and over/);
});

test('setup: three people sign up', async () => {
  // The under-18 rules stay in the code for when min_age comes back down,
  // so open sign-up to 13+ for the rest of the run to keep them checked.
  await setMinAge(13);
  alice = await user('alice', '1990-05-01');
  bob = await user('bob', '1988-02-02');
  tia = await user('tia', yearsAgo(15));
  const kid = await user('kid');
  await fails(kid.rpc('create_profile', { p_handle: `kid_${run}`, p_display_name: 'kid', p_birth_date: '2020-01-01' }), /13 and over/);
  await fails(kid.rpc('create_profile', { p_handle: alice.handle, p_display_name: 'x', p_birth_date: '1990-01-01' }), /taken/);
  const p = await me(alice);
  assert.equal(p.credits, 10);
  assert.equal(p.is_adult, true);
  assert.equal((await me(tia)).is_adult, false);
});

test('signed-out visitors see nothing', async () => {
  const anon = createClient(URL, ANON, opts);
  await fails(anon.from('questions').select('id'));
  await fails(anon.from('statements').select('id'));
});

test('questions: today is the flat Earth, tomorrow stays hidden, under-18s never see sensitive ones', async () => {
  const qs = await ok(alice.from('questions').select('id,text,daily_date,sensitivity,is_event'));
  const today = qs.filter(q => q.daily_date && q.daily_date >= new Date(Date.now() - 864e5).toISOString().slice(0, 10));
  daily = qs.find(q => q.text === 'Is the Earth flat?');
  assert.ok(daily.daily_date, 'flat Earth is a daily question');
  assert.ok(!qs.some(q => q.text === 'Is a hot dog a sandwich?'), "tomorrow's question is hidden");
  assert.ok(today.length >= 1);
  assert.ok(qs.some(q => q.sensitivity === 'sensitive'));
  const tq = await ok(tia.from('questions').select('sensitivity'));
  assert.ok(!tq.some(q => q.sensitivity === 'sensitive'));
  others = qs.filter(q => !q.daily_date && !q.is_event && q.sensitivity === 'standard').map(q => q.id).sort((a, b) => a - b);
});

test('themed packs: every theme has questions, and picks keep both options', async () => {
  const qs = await ok(alice.from('questions').select('text,category,option_yes,option_no').eq('is_event', false));
  const count = t => qs.filter(q => q.category === t).length;
  for (const t of ['Sport', 'Music', 'Film & TV', 'Travel', 'Work', 'Dating', 'Food', 'Mysteries', 'Future', 'Nostalgia', 'Brands'])
    assert.ok(count(t) >= 7, `${t} has ${count(t)}`);
  const pick = qs.find(q => q.text === 'Messi or Ronaldo?');
  assert.deepEqual([pick.option_yes, pick.option_no], ['Messi', 'Ronaldo']);
});

test('the crowd split only shows after you answer', async () => {
  assert.equal(await ok(alice.rpc('question_split', { p_question: daily.id })), null);
  const split = await ok(alice.rpc('answer', { p_question: daily.id, p_value: false }));
  assert.deepEqual(split, { yes: 0, no: 1, total: 1 });
  const s2 = await ok(bob.rpc('answer', { p_question: daily.id, p_value: true }));
  assert.equal(s2.total, 2);
});

test('five answers a day, one always kept for the daily question', async () => {
  // Alice has answered the daily question, so four more.
  for (const id of others.slice(0, 4)) await ok(alice.rpc('answer', { p_question: id, p_value: true }));
  assert.equal((await me(alice)).answers_left_today, 0);
  await fails(alice.rpc('answer', { p_question: others[4], p_value: true }), /kept for the daily question/);
  // Tia hasn't answered the daily question: she still only gets four others, then the daily one.
  for (const id of others.slice(0, 4)) await ok(tia.rpc('answer', { p_question: id, p_value: true }));
  await fails(tia.rpc('answer', { p_question: others[4], p_value: true }), /kept for the daily question/);
  await ok(tia.rpc('answer', { p_question: daily.id, p_value: false }));
});

test('one change of mind a day, hidden from others for a week', async () => {
  // Alice's answers start public, so Bob can see this one.
  const before = await ok(bob.from('statements').select('value').eq('question_id', others[0]).eq('user_id', (await me(alice)).id));
  assert.deepEqual(before, [{ value: true }]);
  await ok(alice.rpc('answer', { p_question: others[0], p_value: false }));
  await fails(alice.rpc('answer', { p_question: others[1], p_value: false }), /change of mind/);
  const after = await ok(bob.from('statements').select('value').eq('question_id', others[0]).eq('user_id', (await me(alice)).id));
  assert.deepEqual(after, [], 'changed answer hidden from Bob');
  const own = await ok(alice.from('statements').select('value').eq('question_id', others[0]).is('superseded_at', null));
  assert.deepEqual(own, [{ value: false }], 'Alice still sees her own');
});

test('visibility: friends-only needs a follow-back, private never shows, under-18s never public', async () => {
  const aliceId = (await me(alice)).id;
  await ok(alice.rpc('set_visibility', { p_question: others[1], p_visibility: 'friends' }));
  await ok(alice.rpc('set_visibility', { p_question: others[2], p_visibility: 'private' }));
  const see = async () => (await ok(bob.from('statements').select('question_id').eq('user_id', aliceId))).map(r => r.question_id);
  assert.ok(!(await see()).includes(others[1]));
  await ok(alice.from('follows').insert({ follower: aliceId, followed: (await me(bob)).id }));
  await ok(bob.from('follows').insert({ follower: (await me(bob)).id, followed: aliceId }));
  assert.ok((await see()).includes(others[1]), 'friends see friends-only answers');
  assert.ok(!(await see()).includes(others[2]), 'private stays private');
  // Tia is 15: her answers default to friends and can't be made public.
  const t = await ok(tia.from('statements').select('visibility').eq('question_id', others[0]));
  assert.deepEqual(t, [{ visibility: 'friends' }]);
  await fails(tia.rpc('set_visibility', { p_question: others[0], p_visibility: 'public' }), /friends at most/);
});

test('new answers start public or friends-only, as app_config says', async () => {
  await setDefaultPublic(0);
  const nia = await user('nia', '1996-06-06');
  const mine = async q => (await ok(nia.from('statements').select('visibility').eq('user_id', (await me(nia)).id).eq('question_id', q)))[0].visibility;
  await ok(nia.rpc('answer', { p_question: others[0], p_value: true }));
  assert.equal(await mine(others[0]), 'friends');
  // She never picked one herself, so nothing carries over and the setting decides.
  await setDefaultPublic(1);
  await ok(nia.rpc('answer', { p_question: others[1], p_value: true }));
  assert.equal(await mine(others[1]), 'public');
});

test('people can only read their own birth date, and can only write through the app functions', async () => {
  await fails(bob.from('profiles').select('birth_date'));
  await ok(bob.from('profiles').select('handle,display_name'));
  await fails(alice.from('statements').insert({ user_id: (await me(alice)).id, question_id: others[5], value: true, visibility: 'public' }));
  await fails(alice.from('credit_ledger').insert({ user_id: (await me(alice)).id, amount: 1000, reason: 'cheat' }));
  await fails(alice.from('statements').update({ value: true }).eq('question_id', daily.id));
});

test('sensitive questions need an 18+ opt-in and start private', async () => {
  const god = await qid(alice, 'Do you believe in God?');
  await fails(bob.rpc('answer', { p_question: god, p_value: true }), /Turn on sensitive/);
  await fails(tia.rpc('set_sensitive_opt_in', { p_on: true }), /over-18s/);
  await ok(bob.rpc('set_sensitive_opt_in', { p_on: true }));
  await ok(bob.rpc('answer', { p_question: god, p_value: true, p_visibility: null }));
  const s = await ok(bob.from('statements').select('visibility').eq('question_id', god));
  assert.deepEqual(s, [{ visibility: 'private' }]);
  await fails(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: god, p_minutes: 60 }), /Sensitive/);
});

test('nobody can list strangers; finding an exact handle still works', async () => {
  const stranger = await user('stranger', '1992-01-01');
  assert.deepEqual((await ok(stranger.from('profiles').select('handle'))).map(r => r.handle), [stranger.handle]);
  const aliceSees = (await ok(alice.from('profiles').select('handle'))).map(r => r.handle);
  assert.ok(aliceSees.includes(bob.handle), 'friends are listed');
  assert.ok(!aliceSees.includes(stranger.handle), 'strangers are not');
  const card = await ok(stranger.rpc('profile_card', { p_handle: alice.handle }));
  assert.equal(card.display_name, 'alice');
  await ok(stranger.from('follows').insert({ follower: (await me(stranger)).id, followed: card.id }));
  assert.ok((await ok(stranger.from('profiles').select('handle'))).some(r => r.handle === alice.handle));
  assert.ok((await ok(alice.from('profiles').select('handle'))).some(r => r.handle === stranger.handle), 'a follower shows up as a request');
  await ok(stranger.rpc('delete_my_account'));
});

test('sending a question costs 2 slashes; answering in time earns 2 and skips the daily limit', async () => {
  const q = others[6];
  await fails(bob.rpc('send_challenge', { p_handle: tia.handle, p_question: q, p_minutes: 60 }), /friends/);
  await fails(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: q, p_minutes: 60 }), /yourself first/);
  await ok(bob.rpc('answer', { p_question: q, p_value: true }));
  await fails(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: q, p_minutes: 5 }), /1 minute, 1 hour or 1 day/);
  await ok(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: q, p_minutes: 60 }));
  assert.equal((await me(bob)).credits, 8);
  // Alice is out of answers today, but a friend's question still goes through.
  await ok(alice.rpc('answer', { p_question: q, p_value: true }));
  assert.equal((await me(alice)).credits, 12);
  const ch = await ok(alice.from('challenges').select('answered_at'));
  assert.ok(ch[0].answered_at);
  // Her last visibility choice (private) carried over to this answer.
  const v = await ok(alice.from('statements').select('visibility').eq('question_id', q).eq('user_id', (await me(alice)).id));
  assert.deepEqual(v, [{ visibility: 'private' }]);
  // Slashes run out: 8 -> 6 -> 4, down to 1, then refused.
  await ok(bob.rpc('answer', { p_question: others[7], p_value: true }));
  await ok(bob.rpc('answer', { p_question: others[8], p_value: true }));
  await ok(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: others[7], p_minutes: 1440 }));
  await ok(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: others[8], p_minutes: 1 }));
  assert.equal((await me(bob)).credits, 4);
  await ok(admin.from('credit_ledger').insert({ user_id: (await me(bob)).id, amount: -3, reason: 'test' }));
  await fails(bob.rpc('send_challenge', { p_handle: alice.handle, p_question: others[8], p_minutes: 60 }), /costs 2 slashes/);
  await ok(admin.from('credit_ledger').insert({ user_id: (await me(bob)).id, amount: 3, reason: 'test' }));
});

test('predictions are free and build a hit rate', async () => {
  await ok(alice.rpc('predict', { p_kind: 'crowd', p_question: daily.id, p_yes: false }));
  await fails(alice.rpc('predict', { p_kind: 'crowd', p_question: daily.id, p_yes: true }), /already/);
  await fails(alice.rpc('predict', { p_kind: 'crowd', p_question: others[0], p_yes: true }), /today/);
  assert.equal((await me(alice)).credits, 12, 'guessing costs nothing');

  // Bob guesses Alice's answers; each resolves when she answers.
  await ok(bob.rpc('predict', { p_kind: 'friend', p_question: others[7], p_yes: true, p_friend: alice.handle }));
  await ok(bob.rpc('predict', { p_kind: 'friend', p_question: others[8], p_yes: true, p_friend: alice.handle }));
  await fails(bob.rpc('predict', { p_kind: 'friend', p_question: others[9], p_yes: true, p_friend: tia.handle }), /friends/);
  await fails(bob.rpc('predict', { p_kind: 'friend', p_question: others[6], p_yes: true, p_friend: alice.handle }), /already answered/);
  await ok(alice.rpc('answer', { p_question: others[7], p_value: true }));                          // private: guess is void
  await ok(alice.rpc('answer', { p_question: others[8], p_value: true, p_visibility: 'friends' })); // guess was right
  assert.deepEqual((await me(bob)).predictions, { made: 2, resolved: 1, correct: 1, rate: 100 });

  // World event, settled by an editor.
  const ev = await qid(alice, 'Will it snow in London on Christmas Day 2026?');
  await ok(alice.rpc('predict', { p_kind: 'event', p_question: ev, p_yes: true }));
  await fails(alice.rpc('resolve_event', { p_question: ev, p_outcome: false }));
  await ok(admin.rpc('resolve_event', { p_question: ev, p_outcome: false }));
  await fails(alice.rpc('predict', { p_kind: 'event', p_question: ev, p_yes: true }), /closed/);

  // Crowd guess: move today's question to an old date, then resolve. NAH leads 2-1.
  const real = daily.daily_date;
  await ok(admin.from('questions').update({ daily_date: '2000-01-01' }).eq('id', daily.id));
  assert.ok((await ok(admin.rpc('resolve_due'))) >= 1);
  await ok(admin.from('questions').update({ daily_date: real }).eq('id', daily.id));

  assert.deepEqual((await me(alice)).predictions, { made: 2, resolved: 2, correct: 1, rate: 50 });
  const card = await ok(bob.rpc('profile_card', { p_handle: alice.handle }));
  assert.equal(card.predictions.rate, 50);
  assert.equal(card.is_friend, true);
});

test('partner apps write verified answers from the server only', async () => {
  const fivek = await qid(alice, 'Can you run 5k?');
  const aliceId = (await me(alice)).id;
  await fails(alice.rpc('partner_write', { p_user: aliceId, p_question: fivek, p_value: true, p_source: 'strava' }));
  await ok(admin.rpc('partner_write', { p_user: aliceId, p_question: fivek, p_value: true, p_source: 'strava' }));
  const s = await ok(alice.from('statements').select('value,source,verified').eq('question_id', fivek));
  assert.deepEqual(s, [{ value: true, source: 'strava', verified: true }]);
});

test('avatars: pick one, and friends see it', async () => {
  await ok(alice.rpc('set_avatar', { p_avatar: 'owl-red' }));
  assert.equal((await me(alice)).avatar, 'owl-red');
  await fails(alice.rpc('set_avatar', { p_avatar: '<img src=x>' }), /Pick one/);
  await fails(alice.from('profiles').update({ avatar: 'fox-blue' }).eq('handle', alice.handle).select().single());
  assert.deepEqual(await ok(bob.from('profiles').select('avatar').eq('handle', alice.handle)), [{ avatar: 'owl-red' }]);
  assert.equal((await ok(bob.rpc('profile_card', { p_handle: alice.handle }))).avatar, 'owl-red');
  const fa = await ok(bob.rpc('friends_answers', { p_question: daily.id }));
  assert.ok(fa.every(r => 'avatar' in r));
  await ok(alice.rpc('set_avatar', { p_avatar: '' }));
  assert.equal((await me(alice)).avatar, null);
  await ok(alice.rpc('set_avatar', { p_avatar: 'owl-red' }));
});

test('download my data and delete my account', async () => {
  const data = await ok(alice.rpc('export_my_data'));
  assert.equal(data.profile.handle, alice.handle);
  assert.equal(data.email, `alice.${run}@example.com`);
  assert.ok(data.statements.length >= 5);
  for (const k of ['groups', 'questions_sent', 'suggested_questions', 'reports', 'feedback']) assert.ok(Array.isArray(data[k]), k);
  assert.ok(data.questions_sent.length >= 1, 'bob sent alice a question');
  await ok(tia.rpc('delete_my_account'));
  const gone = await ok(admin.from('profiles').select('id').eq('handle', tia.handle));
  assert.deepEqual(gone, []);
});

test('friend groups: invite link, everyone becomes friends, answers per question after you answer', async () => {
  const host = await user('host', '1991-01-01');
  const g1 = await user('gina', '1993-03-03');
  const g2 = await user('gus', '1994-04-04');
  const teen = await user('teen', yearsAgo(16));
  const anon = createClient(URL, ANON, opts);

  const g = await ok(host.rpc('create_group', { p_name: 'Pub quiz lot' }));
  assert.equal(g.name, 'Pub quiz lot');
  const preview = await ok(anon.rpc('group_preview', { p_code: g.invite_code }));
  assert.deepEqual(preview, { name: 'Pub quiz lot', members: 1, invited_by: 'host' });
  await fails(anon.rpc('group_board', { p_group: g.id }));
  await fails(g1.rpc('join_group', { p_code: 'nope' }), /doesn't work/);
  await fails(teen.rpc('join_group', { p_code: g.invite_code }), /over-18s/);
  await ok(g1.rpc('join_group', { p_code: g.invite_code }));
  await ok(g2.rpc('join_group', { p_code: g.invite_code }));
  await ok(g2.rpc('join_group', { p_code: g.invite_code })); // joining twice is harmless

  // Everyone is now friends with everyone.
  assert.equal((await ok(g1.rpc('profile_card', { p_handle: g2.handle }))).is_friend, true);
  assert.equal((await ok(host.rpc('profile_card', { p_handle: g1.handle }))).is_friend, true);
  const members = await ok(g1.from('group_members').select('user_id').eq('group_id', g.id));
  assert.equal(members.length, 3);
  // Outsiders can't see the group.
  assert.deepEqual(await ok(alice.from('groups').select('id').eq('id', g.id)), []);
  await fails(alice.rpc('group_board', { p_group: g.id }), /not in that group/);

  // Board: Gina and Gus answer; the host hasn't, so sees counts only.
  await ok(g1.rpc('answer', { p_question: daily.id, p_value: true }));
  await ok(g2.rpc('answer', { p_question: daily.id, p_value: false, p_visibility: 'friends' }));
  let board = await ok(host.rpc('group_board', { p_group: g.id }));
  let row = board.find(r => r.question_id === daily.id);
  assert.equal(row.answered, 2);
  assert.equal(row.answers, null, 'no peeking before you answer');
  await ok(host.rpc('answer', { p_question: daily.id, p_value: false }));
  board = await ok(host.rpc('group_board', { p_group: g.id }));
  row = board.find(r => r.question_id === daily.id);
  assert.ok(row.answers.every(a => 'avatar' in a));
  assert.deepEqual(row.answers.map(a => [a.name, a.value, a.me]),
    [['host', false, true], ['gina', true, false], ['gus', false, false]]);

  // Private answers stay out of the board.
  await ok(g2.rpc('set_visibility', { p_question: daily.id, p_visibility: 'private' }));
  row = (await ok(host.rpc('group_board', { p_group: g.id }))).find(r => r.question_id === daily.id);
  assert.deepEqual(row.answers.map(a => a.name), ['host', 'gina']);

  // Only the creator can reset the link; the old one stops working.
  await fails(g1.rpc('reset_invite', { p_group: g.id }), /Only the person/);
  const code = await ok(host.rpc('reset_invite', { p_group: g.id }));
  assert.notEqual(code, g.invite_code);
  assert.equal(await ok(anon.rpc('group_preview', { p_code: g.invite_code })), null);

  // Leaving removes you from the board.
  await ok(g2.rpc('leave_group', { p_group: g.id }));
  await fails(g2.rpc('group_board', { p_group: g.id }), /not in that group/);
});

test('leaving or being removed from a group ends the friendships it made', async () => {
  const host = await user('host2', '1990-02-02');
  const [m1, m2, pal] = [await user('mo', '1991-01-01'), await user('mia', '1992-02-02'), await user('pal', '1993-03-03')];
  const id = async c => (await me(c)).id;
  const friends = async (a, b) => (await ok(a.rpc('profile_card', { p_handle: b.handle }))).is_friend;
  // Pal and the host were friends before the group.
  await ok(pal.from('follows').insert({ follower: await id(pal), followed: await id(host) }));
  await ok(host.from('follows').insert({ follower: await id(host), followed: await id(pal) }));
  const g = await ok(host.rpc('create_group', { p_name: 'Five a side' }));
  const other = await ok(host.rpc('create_group', { p_name: 'Book club' }));
  for (const c of [m1, m2, pal]) await ok(c.rpc('join_group', { p_code: g.invite_code }));
  await ok(m2.rpc('join_group', { p_code: other.invite_code }));
  assert.equal(await friends(m1, m2), true);

  // Pal leaves: still friends with the host (made before), not with Mo.
  await ok(pal.rpc('leave_group', { p_group: g.id }));
  assert.equal(await friends(pal, host), true);
  assert.equal(await friends(pal, m1), false);
  assert.deepEqual((await ok(pal.from('profiles').select('handle'))).map(r => r.handle).sort(), [host.handle, pal.handle].sort());

  // Only the creator removes people, and they can't rejoin with the link.
  await fails(m1.rpc('remove_member', { p_group: g.id, p_user: await id(m2) }), /Only the person/);
  await fails(host.rpc('remove_member', { p_group: g.id, p_user: await id(host) }), /Leave the group/);
  await ok(host.rpc('remove_member', { p_group: g.id, p_user: await id(m2) }));
  assert.equal(await friends(m2, m1), false);
  assert.equal(await friends(m2, host), true, 'still friends through the other group');
  await fails(m2.rpc('join_group', { p_code: g.invite_code }), /removed/);
  await fails(m2.rpc('group_board', { p_group: g.id }), /not in that group/);
});

test('friend questions: no approval, only friends see them, 3 slashes to make and free to pass on', async () => {
  const id = async c => (await me(c)).id;
  const [writer, pal1, pal2, outsider] = [await user('writer', '1990-04-04'), await user('pal1', '1991-04-04'),
    await user('pal2', '1992-04-04'), await user('outsider', '1993-04-04')];
  const g = await ok(writer.rpc('create_group', { p_name: 'Quiz' }));
  for (const c of [pal1, pal2]) await ok(c.rpc('join_group', { p_code: g.invite_code }));
  // The outsider is friends with pal1 only.
  await ok(outsider.from('follows').insert({ follower: await id(outsider), followed: await id(pal1) }));
  await ok(pal1.from('follows').insert({ follower: await id(pal1), followed: await id(outsider) }));
  const before = await me(writer);

  await fails(writer.rpc('make_friend_question', { p_text: 'Would you eat a bug for a tenner?', p_value: true, p_handles: [outsider.handle] }), /only send questions to friends/);
  const q = await ok(writer.rpc('make_friend_question', { p_text: 'Would you eat a bug for a tenner?', p_value: true, p_handles: [pal1.handle, pal2.handle] }));
  const after1 = await me(writer);
  assert.equal(before.credits - after1.credits, 3, '3 slashes however many friends get it');
  assert.equal(after1.other_answers_left_today, before.other_answers_left_today, "the writer's own answer is outside the daily five");

  const row = await ok(pal1.from('questions').select('status,audience,category').eq('id', q));
  assert.deepEqual(row, [{ status: 'approved', audience: 'friends', category: 'Friends' }]);
  assert.equal((await ok(outsider.from('questions').select('id').eq('id', q))).length, 0, 'not friends with the writer');
  await fails(outsider.rpc('answer', { p_question: q, p_value: true }), /not found/);

  // Answers never go public, and answering in time earns the reward.
  const pal1Before = (await me(pal1)).credits;
  await ok(pal1.rpc('answer', { p_question: q, p_value: false, p_visibility: 'public' }));
  const s = await ok(pal1.from('statements').select('visibility,via_challenge').eq('question_id', q).eq('user_id', await id(pal1)));
  assert.deepEqual(s, [{ visibility: 'friends', via_challenge: true }]);
  assert.equal((await me(pal1)).credits, pal1Before + 2);
  await fails(pal1.rpc('set_visibility', { p_question: q, p_visibility: 'public' }), /stay with friends/);
  assert.deepEqual(await ok(pal1.rpc('question_split', { p_question: q })), { yes: 1, no: 1, total: 2 });
  // pal1 can't pass it on to someone who isn't the writer's friend, and passing it on is free.
  await fails(pal1.rpc('send_challenge', { p_handle: outsider.handle, p_question: q, p_minutes: 60 }), /friends of the person who wrote it/);
  const pal3 = await user('pal3', '1994-04-04');
  await ok(pal3.rpc('join_group', { p_code: g.invite_code }));
  const pal1Now = (await me(pal1)).credits;
  await ok(pal1.rpc('send_challenge', { p_handle: pal3.handle, p_question: q, p_minutes: 60 }));
  assert.equal((await me(pal1)).credits, pal1Now, 'forwarding a friend question costs nothing');

  // Public questions still wait for a moderator, and cost 5 slashes.
  const pq = await ok(writer.rpc('submit_question', { p_text: 'Is a hot dog a sandwich?', p_category: 'Food' }));
  assert.equal((await me(writer)).credits, after1.credits - 5);
  await ok(admin.from('credit_ledger').insert({ user_id: await id(writer), amount: -2, reason: 'test' }));
  assert.deepEqual(await ok(writer.from('questions').select('status,audience,category').eq('id', pq)), [{ status: 'pending', audience: 'public', category: 'Food' }]);
  assert.equal((await ok(pal1.from('questions').select('id').eq('id', pq))).length, 0, 'nobody else sees it before approval');
  await fails(writer.rpc('submit_question', { p_text: 'Is cereal a soup?' }), /costs 5 slashes and you have 0/);
});

test('stars: only yours, and only on questions you can see', async () => {
  const [a, b] = [await user('stara', '1990-06-06'), await user('starb', '1991-06-06')];
  const q = others[3];
  await ok(a.rpc('set_star', { p_question: q, p_on: true }));
  await ok(a.rpc('set_star', { p_question: q, p_on: true }));
  assert.deepEqual((await ok(a.from('stars').select('question_id'))).map(r => r.question_id), [q]);
  assert.equal((await ok(b.from('stars').select('question_id'))).length, 0, "nobody sees someone else's stars");
  await fails(a.from('stars').insert({ user_id: (await me(a)).id, question_id: others[4] }));
  const pending = await ok(b.rpc('submit_question', { p_text: 'Is a jaffa cake a biscuit?' }));
  await fails(a.rpc('set_star', { p_question: pending, p_on: true }), /not found/);
  const text = (await ok(a.from('questions').select('text').eq('id', q).single())).text;
  assert.deepEqual((await ok(a.rpc('export_my_data'))).starred_questions.map(r => r.text), [text]);
  await ok(a.rpc('set_star', { p_question: q, p_on: false }));
  assert.equal((await ok(a.from('stars').select('question_id'))).length, 0);
});

test('question links: anyone with the link can see and answer, even signed out first', async () => {
  const id = async c => (await me(c)).id;
  const [maker, newbie] = [await user('maker', '1990-07-07'), await user('newbie', '1991-07-07')];
  // A friends-only question made just to share by link: no friends picked.
  const q = await ok(maker.rpc('make_friend_question', { p_text: 'Would you go to space for a week?', p_value: true, p_handles: [] }));
  assert.equal((await me(maker)).credits, 7);
  await fails(newbie.rpc('share_question', { p_question: q }), /questions you wrote/);
  const code = await ok(maker.rpc('share_question', { p_question: q }));
  assert.equal(await ok(maker.rpc('share_question', { p_question: q })), code, 'one link per question');

  // Signed out, the link shows the question and who asked.
  const anon = createClient(URL, ANON, opts);
  assert.deepEqual(await ok(anon.rpc('question_preview', { p_code: code })), { text: 'Would you go to space for a week?', by: 'maker', live: true });
  await fails(anon.rpc('open_question_link', { p_code: code }));
  assert.equal(await ok(anon.rpc('question_preview', { p_code: 'nope' })), null);

  // Not friends, so newbie can't see it until opening the link.
  assert.equal((await ok(newbie.from('questions').select('id').eq('id', q))).length, 0);
  const opened = await ok(newbie.rpc('open_question_link', { p_code: code }));
  assert.equal(opened.id, q);
  assert.equal(opened.by, 'maker');
  assert.equal(opened.friends, false);
  assert.equal((await ok(newbie.from('questions').select('id').eq('id', q))).length, 1);
  const left = (await me(newbie)).other_answers_left_today;
  await ok(newbie.rpc('answer', { p_question: q, p_value: false, p_visibility: 'public' }));
  assert.equal((await me(newbie)).other_answers_left_today, left, "outside the daily five");
  assert.deepEqual(await ok(newbie.rpc('question_split', { p_question: q })), { yes: 1, no: 1, total: 2 });
  // Following the writer from the link sends them a friend request.
  await ok(newbie.from('follows').insert({ follower: await id(newbie), followed: opened.by_id }));
  assert.equal((await ok(newbie.rpc('open_question_link', { p_code: code }))).following, true);
  assert.equal((await ok(newbie.rpc('export_my_data'))).questions_opened_from_links.length, 1);

  // A public question's link only works once a moderator approves it.
  const pq = await ok(maker.rpc('submit_question', { p_text: 'Should the clocks stop changing?' }));
  const pcode = await ok(maker.rpc('share_question', { p_question: pq }));
  assert.equal((await ok(anon.rpc('question_preview', { p_code: pcode }))).live, false);
  await fails(newbie.rpc('open_question_link', { p_code: pcode }), /waiting for a moderator/);
  await ok(admin.from('questions').update({ status: 'approved' }).eq('id', pq));
  assert.equal((await ok(newbie.rpc('open_question_link', { p_code: pcode }))).id, pq);
});

test('feedback lands in a table only its author (and the owner) can read', async () => {
  await ok(bob.rpc('submit_feedback', { p_body: 'Love the flat Earth one', p_context: 'today' }));
  await fails(bob.from('feedback').insert({ body: 'x' }));
  assert.equal((await ok(bob.from('feedback').select('body'))).length, 1);
  assert.equal((await ok(alice.from('feedback').select('body'))).length, 0);
  const all = await ok(admin.from('feedback').select('body,context'));
  assert.deepEqual(all, [{ body: 'Love the flat Earth one', context: 'today' }]);
});
