// The picture on each power-up card. Owned by the graphics thread ("Power-up
// and effect card graphics"); the Today thread owns what the cards do. Change
// anything in here and in powerups.css freely. `p` is today's power-up as the
// server sends it: { kind, rarity, slashes, effect, claimed, ... }.
import React from 'react';
import { Px } from './icons.jsx';
import './powerups.css';

export const RARITY = ['common', 'uncommon', 'rare', 'epic', 'legendary'];

// Effect cards: an icon from icons.jsx and a short caption.
const EFFECT_ART = {
  second_thoughts: ['back', '+1 change'],
  free_post: ['send', 'Free send'],
  peek: ['eye', 'Peek'],
  overtime: ['timer', '+1 hour'],
  mind_reader: ['Friends', 'Who said yeah?'],
  extra_hand: ['shuffle', '+3 cards'],
  called_it: ['predict', 'Guess the split'],
  wildcard: ['star-on', 'Any card'],
};

export function PowerUpArt({ p }) {
  const art = p.effect && EFFECT_ART[p.kind];
  return (
    <div className="pu-art" aria-hidden="true">
      {art ? (
        <>
          <Px name={art[0]} scale={6} />
          <span className="w">{art[1]}</span>
        </>
      ) : (
        <>
          <span className="n">+{p.slashes}</span>
          <span className="w">{p.slashes === 1 ? 'slash' : 'slashes'}</span>
        </>
      )}
    </div>
  );
}
