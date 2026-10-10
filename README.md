# yeah/nah demo

A working proof of concept of yeah/nah: real accounts, a real database and the
prototype's rules enforced on the server. It runs on free tiers.

```
web/       the app people use (React, built to a static site)
supabase/  the database: tables, privacy rules, game rules, 139 questions in 20 themes
tests/     35 end-to-end checks of the rules, run through the same API the app uses
```

## What it does

- Sign up with email and password, then a profile with handle, name and date of birth. **18+ only for now.** The under-18 rules below are still built in, and come back if you lower `min_age` in `app_config` (13 is the floor for UK apps).
- **Today**: a hand of 5 cards a day, starting with the daily question ("Is the Earth flat?" on launch day). Tap left or right to answer, swipe left for the next card and right to go back. The hand is kept on your phone until the next day, answered cards keep their crowd split and friends' answers, and Shuffle swaps the unanswered ones. Questions friends send you are extra green cards, dealt next with the least time left first, and a pink letter sits on the Today tab until you have answered them all or their timers run out. Star questions in the Questions tab and they're dealt in first, then Hot ones, then the rest. Some days the first hand also has a **power-up card**, common to legendary. Slash cards hold 1 to 10 slashes to claim before midnight. Effect cards go in your pocket to use that day: Second thoughts (an extra change of mind), Free post (next send free, even to a whole group), Peek (the split before you answer), Overtime (an hour more on a friend's question), Mind reader (friends' answers before you answer), Extra hand (3 more cards and answers), Called it (guess today's split for 10 slashes) and Wildcard (becomes any card, keeps 7 days). `powerup_chance` in `app_config` is the percent of days with one (50 to start); each card's odds are rows in `powerup_kinds`, and the effects' numbers (`called_it_prize`, `overtime_minutes`, `extra_hand_cards`...) are in `app_config`.
- **Themes**: 139 questions in 20 themes, including Sport, Music, Film & TV, Travel, Work, Dating, Food, Mysteries, Future, Nostalgia and Brands. The Questions tab shows each theme with how many you've answered; tap one to see just those. **Hot ones** is an extra theme on top: the questions people have starred and answered most in the last 7 days, hottest first. Answers to the day's daily question and questions written for friends don't count, a question needs stars or answers from at least 3 different people, and only the list is shown, never counts or names. Stars count 3 times as much as answers. The numbers are `hot_days`, `hot_count` (12), `hot_star_weight` and `hot_min_people` in `app_config`. Picks like "Messi or Ronaldo?" show both names as the answer buttons.
- **Answer stats**: tap the yeah/nah bar on a card you've answered (or More stats under it) and the card flips over to its stats: your friends, each of your groups, age groups, how the split moved day by day, and how people guessed in Future. Only counts come back, and they follow the same rules as names: friends and groups count answers shared with friends, age groups count public answers only, and an age group, a day or the guesses only show once at least `stats_min_people` (3) are in, so nobody can be picked out.
- **5 answers a day**, one always kept for the daily question. **One change of mind a day**, and the changed answer is hidden from others for 7 days.
- **Who sees each answer**: public, friends or private. Your last choice carries over, except sensitive answers, which always start private. Before you pick one, standard answers start public; set `new_answers_public` to 0 in `app_config` to start them friends-only. Under-18s can never be public.
- **Sensitive questions** (religion, politics) need an 18+ opt-in, which is recorded as consent and can be withdrawn.
- **Friends** are people who follow each other. Send friends a question you've answered for 2 slashes each (free play points), one by one or a whole group at once, with a 1 minute, 1 hour or 1 day timer that starts the first time the question is on their screen; they earn 2 slashes for answering in time, and it doesn't use up their daily 5. Everyone starts with 10 slashes.
- **Friend groups**: make a group, tap Invite friends and send the link. Whoever signs up through it joins the group and becomes friends with everyone in it. The Group tab shows, per question, how each member answered, once you've answered it yourself. Private answers stay hidden. Groups are 18+ in the demo. Anyone with the invite link can join, so it's for sending to friends. Leaving a group ends the friendships it made, and whoever made the group can remove someone, who then can't rejoin with the link.
- **Finding people**: you can only see the profiles of people you're connected to (friends, followers, your groups). To add someone new, type their exact handle.
- **Avatars**: each person's pick is saved with `set_avatar('cap-red')` and shown to anyone who can see their name. The picker comes with the retro restyle.
- **Feedback** button on every screen, and a **Report** button on an opened question. Both land in the admin inbox.
- **Admin area** for accounts in the `admins` table (`harley` to start): an Admin button appears in the top bar with a count of what's waiting. Set the daily question for today or any later day, by picking one from the bank or writing a new one. Review questions suggested for everyone (approve, edit, reject with or without giving the slashes back), search and edit or take down any question for everyone, work through reports and feedback with notes, and read the audit log of every suggestion, review and edit, including changes made in the Supabase editors. **Growth** is the virality dashboard: virality (v, worked out the same way slashtax will use it, from `virality_*` in `app_config`), active people today, this week and this month, this week against last, a day-by-day chart (active people, sign-ups, answers, sends, link opens), where new people came from (group invite, question link or on their own), weekly cohorts still answering, friends per person, the public/friends/private split of new answers and slashes made and spent. It's totals and percentages only, never people, and leaves out accounts with unlimited slashes. The database checks every admin action, so the button being hidden isn't what keeps people out. Add an admin in the SQL Editor with `insert into public.admins (user_id) select id from public.profiles where handle = 'handle';`.
- **Future** (was Predict): guess the crowd on today's question, guess a friend's answer, or guess world events. Each builds a hit rate shown on your profile. It starts locked: unlocking costs 100 slashes once (`future_unlock_cost`) and needs a date of birth showing 18 or over, which keeps throwaway accounts out. After that, guesses are free. The tab explains that prediction markets have no house.
- **Make a question**: for friends, it's live straight away, only your friends can see it, answers never go public, and it costs 3 slashes however many friends you send it to. Passing a friend question on is free. Any question you write, and any everyday question from the Send panel's Link button, can be shared as your own link. People without an account can answer it and 4 more questions on the sign-up page (`guest_answers` in `app_config`, 5 in all), and see how everyone answered each one. Signing up saves those answers to the new profile without using up that day's answers, and sends you a friend request. Today's question is only in that first hand when it's the one that was linked, so it's still there to answer after signing up. For everyone, it waits for a moderator and costs 5 slashes.
- **Download my data** (everything held about you, as a file) and **delete my account** (UK GDPR).
- **Privacy notice** at `/privacy.html` (`web/public/privacy.html`), linked from sign-up and the profile: what's kept, who sees it, how to delete it. Deletion and other requests go through the Feedback button for now; add a name and contact email before sharing beyond friends.
- Partner apps (Strava etc.) can write verified answers through a server-only function, ready for phase 2.

All the numbers (5 a day, slash costs, 7 days hidden, minimum age...) live in the `app_config` table, so you can change them in the Supabase table editor without touching code. To give an account unlimited slashes (for trying things out), run `select public.give_unlimited_slashes('handle');` in the SQL Editor: spending still works but costs that account nothing, and the app shows ∞. The `harley` account gets this automatically.

## Put it online (about 20 minutes, £0)

You need a GitHub account (free), a Supabase account (free) and a Cloudflare account (free).

### 1. Database: Supabase

1. Create a project at [supabase.com](https://supabase.com). Pick region **West EU (London)** and save the database password somewhere safe.
2. Open **SQL Editor**, paste the whole of `supabase/setup-all.sql`, and press Run. It builds the database and loads the 139 questions, and today becomes launch day. (It is all the migrations and the seed file joined together.)
3. Check **Table Editor > questions** shows 141 rows (139 questions and 2 world events).
4. Go to **Authentication > Sign In / Providers > Email** and turn **Confirm email** off. Supabase's built-in email only sends 2 emails an hour and only to your own team, so the demo uses passwords without email confirmation. Turn it back on once you add an email service (see below).
5. Go to **Project Settings > API** and copy the **Project URL** and the **anon public** key.

Rules that run on a timer (filling tomorrow's daily question, settling crowd guesses) are scheduled automatically with pg_cron when you run the migration.

### Updating a database you already set up

Run only the migration files newer than your setup, in date order, in the SQL Editor. If you set up with friend groups but before 2026-10-10, paste `supabase/update-after-groups.sql` instead: it holds every later update (18+ and themes, the privacy fixes, the complete data download, avatars, slashes, question costs and friend questions, stars, question links, the Future unlock, power-up and effect cards, unlimited slashes for the owner's account, friend requests from question links, sharing any question as a link, Hot ones, answering from a link before signing up, friends' timers starting when the question is first seen, the Growth dashboard, answer stats) and is safe to run more than once. If you set up before friend groups existed, run `supabase/migrations/20261009000000_groups.sql` first.

### 2. App: Cloudflare Pages

1. Put this folder in a GitHub repository (or ask Claude to push it to one).
2. In Cloudflare, go to **Workers & Pages > Create > Pages > Connect to Git** and pick the repository.
3. Settings: root directory `web`, build command `npm run build`, output directory `dist`.
4. Add two environment variables: `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` with the values from step 1.5.
5. Deploy. You get a `https://<name>.pages.dev` link to share. Every push to GitHub redeploys.

#### Your own address (optional)

To serve the demo from a domain you own, use a subdomain such as `yeahnah.cookiebadboy.com` so anything already on the main domain keeps working.

1. In Cloudflare, open **Workers & Pages**, pick the project, go to **Custom domains** and choose **Set up a custom domain**. Enter `yeahnah.cookiebadboy.com` and continue. Do this before touching DNS; a DNS record pointing at Pages without this step gives a 522 error.
2. If the domain's DNS is already on Cloudflare, it adds the record for you. If not, add a **CNAME** record at your domain registrar: name `yeahnah`, target `<project>.pages.dev`. Cloudflare then checks it and issues the HTTPS certificate on its own.
3. In Supabase, go to **Authentication > URL Configuration**. Set **Site URL** to `https://yeahnah.cookiebadboy.com` and add `https://yeahnah.cookiebadboy.com/**` under **Redirect URLs**, so sign-in emails link to the right place once you turn them on.

The `pages.dev` link keeps working. Invite links use whichever address the inviter has open, so share the new one. Sign-ins are kept per address, so people who signed in on the old link sign in once more on the new one.

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
-- see questions waiting for a moderator, then approve or reject one
select id, text, category, created_at from questions where status = 'pending' order by id;
update questions set status = 'approved' where id = 123;   -- or 'rejected'
-- schedule a daily question
update questions set daily_date = '2026-10-20' where id = 45;
-- add a world event, then settle it
insert into questions (text, category, is_event, closes_at)
values ('Will England beat France on Saturday?', 'World events', true, '2026-10-17 15:00+01');
select resolve_event(id, true) from questions where text = 'Will England beat France on Saturday?';
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
