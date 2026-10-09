// The picture on each power-up card. Owned by the graphics thread ("Power-up
// and effect card graphics"); the Today thread owns what the cards do. Change
// anything in here and in powerups.css freely. `p` is today's power-up as the
// server sends it: { kind, rarity, slashes, effect, claimed, ... }.
import React from 'react';
import './powerups.css';

export const RARITY = ['common', 'uncommon', 'rare', 'epic', 'legendary'];

// Each card is drawn as a short run of text in its rarity colour, plus a caption.
// The pixel font's * is a small raised blob, so * is drawn as a pixel asterisk instead.
const ART = {
  loose_change: '/',
  pocket_money: '//',
  lucky_find: '///',
  windfall: '/*5',
  golden_slash: '/*?!',
  second_thoughts: '<-',
  free_post: '->',
  peek: '<O>',
  overtime: 'T-',
  mind_reader: 'Y/N?',
  extra_hand: '+3',
  called_it: 'x/x',
  wildcard: '[]!',
};
const CAPTION = {
  second_thoughts: '+1 change',
  free_post: 'Free send',
  peek: 'Peek',
  overtime: '+1 hour',
  mind_reader: 'Who said yeah?',
  extra_hand: '+3 cards',
  called_it: 'Guess the split',
  wildcard: 'Any card',
};

const Star = () => (
  <svg className="star" viewBox="0 0 5 5" shapeRendering="crispEdges">
    <path fill="currentColor" d="M2 0h1v5h-1zM0 1h1v1h-1zM4 1h1v1h-1zM1 2h3v1h-3zM0 3h1v1h-1zM4 3h1v1h-1z" />
  </svg>
);

export function PowerUpArt({ p }) {
  const glyph = ART[p.kind] ?? (p.effect ? '?' : `+${p.slashes}`);
  const caption = p.effect ? CAPTION[p.kind] ?? '' : `+${p.slashes} ${p.slashes === 1 ? 'slash' : 'slashes'}`;
  return (
    <div className="pu-art" aria-hidden="true">
      <span className="g">{glyph.split(/(\*)/).map((s, k) => (s === '*' ? <Star key={k} /> : s))}</span>
      <span className="w">{caption}</span>
    </div>
  );
}
