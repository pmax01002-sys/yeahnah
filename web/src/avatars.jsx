// The six 16x16 pixel avatars from the retro template (retro-template/avatars in
// the project files). Each comes in two tones, and the tone is your team: green
// is Team Yeah, red is Team Nah. A pick is stored in profiles.avatar as
// "<sprite>-<tone>", e.g. "owl-green"; no pick shows as cap-red.
// Shades in the rows: . paper, a light (1px dither of the accent), b accent, # ink.
import React, { useId, useState } from 'react';

export const SPRITES = {"cap":{"name":"Cap","rows":["................",".....######.....","....#bbbbbb#....","...#bbbaabbb#...","...#bbbbbbbb#...","..############..","..#bb......bb#..","...#.#....#.#...","...#.#....#.#...","...#.a....a.#...","....#..bb..#....",".....######.....","......#..#......","...###bbbb###...","..#aaabbbbaaa#..",".#aaaabbbbaaaa#."]},"specs":{"name":"Specs","rows":["................",".....######.....","...##bbbbbb##...","..#bbbbbbbbbb#..","..#bbbbbbbbbb#..","..#bb######bb#..","..#b#......#b#..","..#b###..###b#..","..#b#a####a#b#..","..#b###..###b#..","..#bb#.bb.#bb#..","..#bbb####bbb#..","...####..####...","....#aa##aa#....","..##aaa##aaa##..",".#aaaaa##aaaaa#."]},"pigtails":{"name":"Pigtails","rows":["..###......###..",".#bbb#....#bbb#.",".#bbbb####bbbb#.","..##bbbbbbbb##..","...#bbbbbbbb#...","...#bbb..bbb#...","...#b......b#...","...#.#....#.#...","...#.#....#.#...","...#.a....a.#...","....#..bb..#....",".....######.....","......#..#......","...###aaaa###...","..#bbbaaaabbb#..",".#bbbbaaaabbbb#."]},"owl":{"name":"Owl","rows":["................","..##........##..","..#b#......#b#..","..#bb######bb#..","..#bbbbbbbbbb#..",".#bb###bb###bb#.",".#b#...##...#b#.",".#b#.#.##.#.#b#.",".#b#...##...#b#.",".#bb###aa###bb#.",".#bbbbb##bbbbb#.",".#bbaaaaaaaabb#.",".#bbaa#aa#aabb#.","..#bbaaaaaabb#..","...#bbbbbbbb#...","....##....##...."]},"frog":{"name":"Frog","rows":["................","..####....####..",".#....#..#....#.",".#.##.#..#.##.#.",".#.##.####.##.#.",".#....#aa#....#.","#a####aaaa####a#","#aaaaaaaaaaaaaa#","#aaaaaaaaaaaaaa#","#ab##########ba#","#aabbbbbbbbbbaa#",".#aaaaaaaaaaaa#.","..##aaaaaaaa##..","...#b######b#...","..#bb#....#bb#..","..####....####.."]},"fox":{"name":"Fox","rows":["................",".##..........##.",".#b#........#b#.",".#bb#......#bb#.",".#abb######bba#.",".#aaaaaaaaaaaa#.",".#aaaaaaaaaaaa#.",".#aa#aaaaaa#aa#.",".#aa#aaaaaa#aa#.",".#a...aaaa...a#.","..#....aa....#..","...#........#...","....#......#....",".....#....#.....","......#..#......","......####......"]}};
export const TEAMS = [['green', 'Yeah'], ['red', 'Nah']];
const DEFAULT = ['cap', 'red'];

export function parseAvatar(v) {
  const [id, tone] = (v || '').split('-');
  return SPRITES[id] && (tone === 'red' || tone === 'green') ? [id, tone] : null;
}
export const teamOf = v => { const p = parseAvatar(v); return p ? (p[1] === 'green' ? 'Yeah' : 'Nah') : null; };

// px should be a multiple of 16 so every sprite pixel lands on whole screen pixels.
export function Avatar({ value, px = 32, label }) {
  const uid = useId().replace(/:/g, '');
  const [id, tone] = parseAvatar(value) || DEFAULT;
  const acc = `var(--av-${tone})`, k = px / 16, dot = `avd${uid}`;
  const fill = { a: `url(#${dot})`, b: acc, '#': 'var(--ink)' };
  const rects = [];
  SPRITES[id].rows.forEach((row, y) => {
    for (let x = 0; x < 16;) {
      const c = row[x], s = x;
      while (x < 16 && row[x] === c) x++;
      if (c !== '.') rects.push(<rect key={`${y}-${s}`} x={s} y={y} width={x - s} height="1" style={{ fill: fill[c] }} />);
    }
  });
  return (
    <svg className="av" viewBox="0 0 16 16" width={px} height={px} shapeRendering="crispEdges"
      role={label ? 'img' : undefined} aria-label={label} aria-hidden={label ? undefined : 'true'} focusable="false">
      <defs>
        <pattern id={dot} patternUnits="userSpaceOnUse" width={2 / k} height={2 / k}>
          <rect width={2 / k} height={2 / k} style={{ fill: 'var(--surface)' }} />
          <rect width={1 / k} height={1 / k} style={{ fill: acc }} />
          <rect x={1 / k} y={1 / k} width={1 / k} height={1 / k} style={{ fill: acc }} />
        </pattern>
      </defs>
      <rect width="16" height="16" style={{ fill: 'var(--surface)' }} />
      {rects}
    </svg>
  );
}

// Pick a team first, then one of the six avatars in that team's colour.
export function AvatarPicker({ value, onSave, onCancel }) {
  const [id0, tone0] = parseAvatar(value) || [DEFAULT[0], null];
  const [id, setId] = useState(id0);
  const [tone, setTone] = useState(tone0);
  const [busy, setBusy] = useState(false);
  return (
    <div className="panel av-picker">
      <span className="label">Pick a team</span>
      <div className="av-teams" role="group" aria-label="Team">
        {TEAMS.map(([t, name]) => (
          <button key={t} className={`av-team ${t}`} aria-pressed={tone === t} onClick={() => setTone(t)}>
            <Avatar value={`${id}-${t}`} px={32} /> Team {name}
          </button>
        ))}
      </div>
      {tone && <>
        <span className="label">Pick your avatar</span>
        <div className="av-grid" role="group" aria-label="Avatar">
          {Object.entries(SPRITES).map(([k, sp]) => (
            <button key={k} aria-pressed={k === id} onClick={() => setId(k)}>
              <Avatar value={`${k}-${tone}`} px={48} /><span>{sp.name}</span>
            </button>
          ))}
        </div>
      </>}
      <div className="inline">
        <button className="solid" disabled={!tone || busy}
          onClick={async () => { setBusy(true); try { await onSave(`${id}-${tone}`); } finally { setBusy(false); } }}>Save</button>
        <button className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}
