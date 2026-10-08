-- Adults only for now, and 79 themed questions in 11 themes.
--
-- Sign-up is 18+ while the demo is shared with friends. The under-18 rules
-- (friends-only answers, no sensitive questions, no groups) stay in place,
-- so lowering min_age in app_config turns teen accounts back on later.
--
-- Safe to run twice: questions already in the bank are skipped.

update public.app_config set value = 18 where key = 'min_age';

create or replace function public.create_profile(p_handle text, p_display_name text, p_birth_date date)
returns void language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'Sign in first' using errcode = '28000'; end if;
  if p_birth_date is null or age(p_birth_date) < make_interval(years => public.cfg('min_age')) then
    raise exception 'yeah/nah is for people aged % and over', public.cfg('min_age');
  end if;
  insert into public.profiles (id, handle, display_name, birth_date)
  values (uid, lower(trim(p_handle)), trim(p_display_name), p_birth_date);
  insert into public.consents (user_id, purpose) values (uid, 'terms');
  insert into public.credit_ledger (user_id, amount, reason)
  values (uid, public.cfg('signup_credits'), 'signup');
exception
  when unique_violation then raise exception 'That handle is taken';
  when check_violation then raise exception 'Handles are 3 to 20 letters, numbers or underscores';
end $$;

-- Themed packs. Picks ("Messi or Ronaldo?") are stored as yes/no like the
-- rest: the first option is YES.
insert into public.questions (text, category, sensitivity, option_yes, option_no, emoji_yes, emoji_no)
select v.text, v.category, v.sensitivity::public.sensitivity, v.option_yes, v.option_no, v.emoji_yes, v.emoji_no
from (values
  ('Is football overrated?', 'Sport', 'standard', null, null, null, null),
  ('Should VAR be scrapped?', 'Sport', 'standard', null, null, null, null),
  ('Is darts a real sport?', 'Sport', 'standard', null, null, null, null),
  ('Is esports a real sport?', 'Sport', 'standard', null, null, null, null),
  ('Should athletes caught doping be banned for life?', 'Sport', 'standard', null, null, null, null),
  ('Should the UK host the Olympics again?', 'Sport', 'standard', null, null, null, null),
  ('Is golf boring to watch?', 'Sport', 'standard', null, null, null, null),
  ('Messi or Ronaldo?', 'Sport', 'standard', 'Messi', 'Ronaldo', '🇦🇷', '🇵🇹'),
  ('Rugby or football?', 'Sport', 'standard', 'Rugby', 'Football', '🏉', '⚽'),
  ('Is vinyl better than streaming?', 'Music', 'standard', null, null, null, null),
  ('Should Eurovision be taken seriously?', 'Music', 'standard', null, null, null, null),
  ('Is karaoke fun?', 'Music', 'standard', null, null, null, null),
  ('Do you skip songs before they finish?', 'Music', 'standard', null, null, null, null),
  ('Have you ever been to a music festival?', 'Music', 'standard', null, null, null, null),
  ('Oasis or Blur?', 'Music', 'standard', 'Oasis', 'Blur', '🎸', '🎹'),
  ('Beatles or Stones?', 'Music', 'standard', 'Beatles', 'Stones', '🪲', '👅'),
  ('Is the book always better than the film?', 'Film & TV', 'standard', null, null, null, null),
  ('Is Die Hard a Christmas film?', 'Film & TV', 'standard', null, null, null, null),
  ('Have you ever cried at a film?', 'Film & TV', 'standard', null, null, null, null),
  ('Should films be shorter than two hours?', 'Film & TV', 'standard', null, null, null, null),
  ('Do you watch TV with subtitles on?', 'Film & TV', 'standard', null, null, null, null),
  ('Do you secretly enjoy reality TV?', 'Film & TV', 'standard', null, null, null, null),
  ('Marvel or DC?', 'Film & TV', 'standard', 'Marvel', 'DC', '🦸', '🦇'),
  ('Is a staycation better than going abroad?', 'Travel', 'standard', null, null, null, null),
  ('Would you go on holiday alone?', 'Travel', 'standard', null, null, null, null),
  ('Is camping a real holiday?', 'Travel', 'standard', null, null, null, null),
  ('Should you always learn a few words of the local language?', 'Travel', 'standard', null, null, null, null),
  ('Is it OK to recline on a train?', 'Travel', 'standard', null, null, null, null),
  ('Window or aisle?', 'Travel', 'standard', 'Window', 'Aisle', '🪟', '🚶'),
  ('City break or beach holiday?', 'Travel', 'standard', 'City break', 'Beach', '🏙️', '🏝️'),
  ('Should the four-day week be standard?', 'Work', 'standard', null, null, null, null),
  ('Should everyone know what their colleagues earn?', 'Work', 'standard', null, null, null, null),
  ('Would you take a pay cut to work from home?', 'Work', 'standard', null, null, null, null),
  ('Is it rude to wear headphones in the office?', 'Work', 'standard', null, null, null, null),
  ('Is it OK to look for jobs while at work?', 'Work', 'standard', null, null, null, null),
  ('Would you work unpaid for a year to land your dream job?', 'Work', 'standard', null, null, null, null),
  ('Do you like your job?', 'Work', 'personal', null, null, null, null),
  ('Should couples share their phone passwords?', 'Dating', 'standard', null, null, null, null),
  ('Is it OK to date a friend''s ex?', 'Dating', 'standard', null, null, null, null),
  ('Do you believe in soulmates?', 'Dating', 'standard', null, null, null, null),
  ('Is it OK to break up by text?', 'Dating', 'standard', null, null, null, null),
  ('Would you date someone with opposite politics?', 'Dating', 'standard', null, null, null, null),
  ('Should you meet a partner''s parents within three months?', 'Dating', 'standard', null, null, null, null),
  ('Have you ever used a dating app?', 'Dating', 'personal', null, null, null, null),
  ('Is a Jaffa Cake a biscuit?', 'Food', 'standard', null, null, null, null),
  ('Is cereal a soup?', 'Food', 'standard', null, null, null, null),
  ('Is brunch overrated?', 'Food', 'standard', null, null, null, null),
  ('Should ketchup be kept in the fridge?', 'Food', 'standard', null, null, null, null),
  ('Is a full English the best breakfast?', 'Food', 'standard', null, null, null, null),
  ('Milk in first?', 'Food', 'standard', null, null, null, null),
  ('Cheese or chocolate?', 'Food', 'standard', 'Cheese', 'Chocolate', '🧀', '🍫'),
  ('Is the Loch Ness Monster real?', 'Mysteries', 'standard', null, null, null, null),
  ('Have aliens visited Earth?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Area 51 hiding something?', 'Mysteries', 'standard', null, null, null, null),
  ('Are ghosts real?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Elvis still alive?', 'Mysteries', 'standard', null, null, null, null),
  ('Did Atlantis exist?', 'Mysteries', 'standard', null, null, null, null),
  ('Is Bigfoot real?', 'Mysteries', 'standard', null, null, null, null),
  ('Would you get a brain chip if it was proven safe?', 'Future', 'standard', null, null, null, null),
  ('Should AI-made art be allowed to win prizes?', 'Future', 'standard', null, null, null, null),
  ('Would you want to live to 150?', 'Future', 'standard', null, null, null, null),
  ('Is social media doing more harm than good?', 'Future', 'standard', null, null, null, null),
  ('Would you swap your smartphone for a basic phone for a month?', 'Future', 'standard', null, null, null, null),
  ('Should cash be phased out?', 'Future', 'standard', null, null, null, null),
  ('Would you trust a robot to care for your parents?', 'Future', 'standard', null, null, null, null),
  ('Was music better in the 90s?', 'Nostalgia', 'standard', null, null, null, null),
  ('Do you miss life before smartphones?', 'Nostalgia', 'standard', null, null, null, null),
  ('Were the original Pokémon the best?', 'Nostalgia', 'standard', null, null, null, null),
  ('Should Blockbuster come back?', 'Nostalgia', 'standard', null, null, null, null),
  ('Was childhood better before the internet?', 'Nostalgia', 'standard', null, null, null, null),
  ('Did you have a Tamagotchi?', 'Nostalgia', 'standard', null, null, null, null),
  ('Nokia 3310 or Motorola Razr?', 'Nostalgia', 'standard', 'Nokia 3310', 'Razr', '🧱', '📞'),
  ('Spotify or Apple Music?', 'Brands', 'standard', 'Spotify', 'Apple Music', '🟢', '🍎'),
  ('Netflix or Disney+?', 'Brands', 'standard', 'Netflix', 'Disney+', '🎬', '🏰'),
  ('PlayStation or Xbox?', 'Brands', 'standard', 'PlayStation', 'Xbox', '🎮', '🟩'),
  ('Costa or Starbucks?', 'Brands', 'standard', 'Costa', 'Starbucks', '☕', '🧜'),
  ('Tesco or Sainsbury''s?', 'Brands', 'standard', 'Tesco', 'Sainsbury''s', '🛒', '🧡'),
  ('Uber or a black cab?', 'Brands', 'standard', 'Uber', 'Black cab', '🚗', '🚕'),
  ('Amazon or the high street?', 'Brands', 'standard', 'Amazon', 'High street', '📦', '🏪')
) as v(text, category, sensitivity, option_yes, option_no, emoji_yes, emoji_no)
where not exists (select 1 from public.questions q where q.text = v.text);

notify pgrst, 'reload schema';
