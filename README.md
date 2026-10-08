# yeah/nah demo

A working proof of concept of yeah/nah: real accounts, a real database and the
prototype's rules enforced on the server. It runs on free tiers.

```
web/       the app people use (React, built to a static site)
supabase/  the database: tables, privacy rules, game rules, 60 seed questions
tests/     15 end-to-end checks of the rules, run through the same API the app uses
```

## What it does

- Sign up with email and password, then a profile with handle, name and date of birth (13+ only).
- **Today**: the daily question ("Is the Earth flat?" on launch day). The crowd split and friends' answers appear only after you answer.
- **5 answers a day**, one always kept for the daily question. **One change of mind a day**, and the changed answer is hidden from others for 7 days.
- **Who sees each answer**: public, friends or private. Your last choice carries over, except sensitive answers, which always start private. Under-18s can never be public.
- **Sensitive questions** (religion, politics) need an 18+ opt-in, which is recorded as consent and can be withdrawn.
- **Friends** are people who follow each other. Send a friend a question for 3 credits with a 1 minute, 1 hour or 1 day timer; they earn 2 credits for answering in time, and it doesn't use up their daily 5. Everyone starts with 10 credits.
- **Friend groups**: make a group, tap Invite friends and send the link. Whoever signs up through it joins the group and becomes friends with everyone in it. The Group tab shows, per question, how each member answered, once you've answered it yourself. Private answers stay hidden. Groups are 18+ in the demo.
- **Feedback** button on every screen. Messages land in the `feedback` table.
- **Predict** (free): guess the crowd on today's question, guess a friend's answer, or guess world events. Each builds a hit rate shown on your profile.
- **Suggest a question**, which waits for a moderator.
- **Download my data** and **delete my account** (UK GDPR).
- Partner apps (Strava etc.) can write verified answers through a server-only function, ready for phase 2.

All the numbers (5 a day, 3 credits, 7 days hidden...) live in the `app_config` table, so you can change them in the Supabase table editor without touching code.

## Put it online (about 20 minutes, £0)

You need a GitHub account (free), a Supabase account (free) and a Cloudflare account (free).

### 1. Database: Supabase

1. Create a project at [supabase.com](https://supabase.com). Pick region **West EU (London)** and save the database password somewhere safe.
2. Open **SQL Editor**, paste the whole of `supabase/setup-all.sql`, and press Run. It builds the database and loads the 60 questions, and today becomes launch day. (It is all the migrations and the seed file joined together.)
3. Check **Table Editor > questions** shows 62 rows.
4. Go to **Authentication > Sign In / Providers > Email** and turn **Confirm email** off. Supabase's built-in email only sends 2 emails an hour and only to your own team, so the demo uses passwords without email confirmation. Turn it back on once you add an email service (see below).
5. Go to **Project Settings > API** and copy the **Project URL** and the **anon public** key.

Rules that run on a timer (filling tomorrow's daily question, settling crowd guesses) are scheduled automatically with pg_cron when you run the migration.

### Updating a database you already set up

Run only the migration files newer than your setup, in date order, in the SQL Editor. For example, if you ran `setup-all.sql` before friend groups existed, run `supabase/migrations/20261009000000_groups.sql`.

### 2. App: Cloudflare Pages

1. Put this folder in a GitHub repository (or ask Claude to push it to one).
2. In Cloudflare, go to **Workers & Pages > Create > Pages > Connect to Git** and pick the repository.
3. Settings: root directory `web`, build command `npm run build`, output directory `dist`.
4. Add two environment variables: `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` with the values from step 1.5.
5. Deploy. You get a `https://<name>.pages.dev` link to share. Every push to GitHub redeploys.

The anon key is meant to be public: row-level security in the database decides what each signed-in person can see. Never put the `service_role` key in the app.

On a phone, open the link and "Add to Home Screen" to get an app icon.

### Running things yourself

```
cd web && cp .env.example .env.local   # fill in the two values
npm install && npm run dev
```

The rule checks create test users, so run them only against a throwaway project with Confirm email off:

```
cd tests && npm install
SUPABASE_URL=... SUPABASE_ANON_KEY=... SUPABASE_SERVICE_KEY=... npm test
```

### Admin jobs (Supabase SQL Editor)

```sql
-- approve a suggested question
update questions set status = 'approved' where id = 123;
-- schedule a daily question
update questions set daily_date = '2026-10-20' where id = 45;
-- add a world event, then settle it
insert into questions (text, category, is_event, closes_at)
values ('Will England beat France on Saturday?', 'World events', true, '2026-10-17 15:00+01');
select resolve_event(63, true);
-- open reports
select * from reports where status = 'open';
-- read feedback, newest first, with who sent it
select f.created_at, p.display_name, f.context, f.body
from feedback f left join profiles p on p.id = f.user_id order by f.created_at desc;
-- see groups and who is in them
select g.name, p.display_name from groups g
join group_members m on m.group_id = g.id join profiles p on p.id = m.user_id order by g.name;
```

## Not in the demo yet

Push notifications, magic-link and Google/Apple sign-in, age estimation, device checks against vote stuffing, a moderator screen, the real Strava connection, and anything with real money. The real-money side stays in a separate, licensed system and never shares this database.
