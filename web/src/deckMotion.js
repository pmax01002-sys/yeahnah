import { useCallback, useEffect, useLayoutEffect, useRef } from 'react';

// ---------------------------------------------------------------------------
// Card stack motion, after Balatro. Every card sits on springs, so moves
// overshoot a touch and settle; a dragged card leans into the way it's moving;
// cards are dealt in from below and discarded off to the right; the top card
// tilts towards a mouse; and answering gives it a quick pop.
//
// Transforms are written straight to the DOM from one animation-frame loop,
// so a drag never waits on a React render, and the loop stops once every card
// has settled. At rest a card has no transform at all, so its text stays crisp.
// ---------------------------------------------------------------------------

const reduced = () => typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches;

// k is stiffness, c is damping: less damping, more bounce.
const SPRING = {
  pos: { k: 230, c: 22 },
  lean: { k: 170, c: 11 },
  tilt: { k: 140, c: 14 },
  scale: { k: 380, c: 14 },
};
const CALM = { k: 500, c: 45 }; // no overshoot, for reduced motion
const KEYS = ['x', 'y', 'r', 's', 'rx', 'ry'];
const SPRING_OF = { x: 'pos', y: 'pos', r: 'lean', s: 'scale', rx: 'tilt', ry: 'tilt' };
const BEHIND = 4; // cards deeper than this sit exactly under the fourth, out of sight

// A steady small angle per card, so the pile looks hand-stacked rather than ruled.
function jitter(id) {
  let h = 7;
  for (const ch of String(id)) h = (h * 31 + ch.charCodeAt(0)) | 0;
  return (h % 1000) / 1000; // -1 to 1
}

function pose(id, slot) {
  if (slot === 0) return { x: 0, y: 0, r: 0, s: 1, rx: 0, ry: 0 };
  const k = Math.min(slot, BEHIND);
  return { x: k * 5, y: k * 6, r: jitter(id) * 2.4, s: 1 - k * 0.02, rx: 0, ry: 0 };
}

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));

class DeckMotion {
  constructor() {
    this.cards = new Map(); // id -> card
    this.ghosts = new Set(); // discarded cards flying away
    this.top = null;
    this.drag = null;
    this.hover = null;
    this.raf = 0;
    this.last = 0;
    this.dir = 0; // -1 when the last move went forward, 1 when it went back
    this.opts = { swipe: () => {}, can: false };
    this.tick = this.tick.bind(this);
  }

  width() {
    const c = this.cards.get(this.top) || this.cards.values().next().value;
    return c?.el?.offsetWidth || 360;
  }

  make(el, from) {
    return { el, v: { ...from }, vel: { x: 0, y: 0, r: 0, s: 0, rx: 0, ry: 0 }, to: { ...from }, slot: null, z: 0, via: null, delay: 0 };
  }

  register(id, el) {
    const old = this.cards.get(id);
    if (!el) {
      if (old) { old.off(); this.cards.delete(id); this.discard(old); }
      return;
    }
    if (old?.el === el) return;
    const w = this.width();
    // New cards are dealt in from below and to the right, as if drawn from a pile.
    const c = this.make(el, reduced() ? pose(id, 0) : { x: w * 0.45, y: 320, r: 16, s: 0.92, rx: 0, ry: 0 });
    c.off = this.listen(id, el);
    this.cards.set(id, c);
    this.write(c);
  }

  // React is about to remove a card (a shuffle swapped it out). Leave a copy in
  // its place and throw that off to the right, so it's discarded, not deleted.
  discard(c) {
    const parent = c.el.parentNode;
    if (!parent || reduced() || c.slot === null || c.slot > BEHIND) return;
    const ghost = c.el.cloneNode(true);
    ghost.removeAttribute('id');
    ghost.inert = true;
    ghost.style.pointerEvents = 'none';
    ghost.setAttribute('aria-hidden', 'true');
    parent.appendChild(ghost);
    const g = this.make(ghost, c.v);
    g.vel = { ...c.vel };
    g.z = c.z;
    g.to = { x: this.width() * 1.3, y: -60 - Math.random() * 60, r: 24 + Math.random() * 12, s: 0.95, rx: 0, ry: 0 };
    g.delay = (BEHIND - Math.min(c.slot, BEHIND)) * 35; // the top card goes last
    this.ghosts.add(g);
    this.kick();
  }

  // slots: id -> 0 for the top card, then 1, 2, 3... for the cards behind it
  layout(slots) {
    const w = this.width();
    const dir = this.dir;
    this.dir = 0;
    const top = Object.keys(slots).find(id => slots[id] === 0) ?? null;
    if (top !== this.top) this.hover = null;
    this.top = top;
    let deal = 0;
    const fresh = [...this.cards].filter(([id, c]) => c.slot === null && slots[id] !== undefined)
      .sort((a, b) => slots[b[0]] - slots[a[0]]);
    for (const [id, c] of fresh) c.delay = deal++ * 55; // deepest first, the top card lands last
    for (const [id, c] of this.cards) {
      const slot = slots[id];
      if (slot === undefined) continue;
      const was = c.slot;
      c.slot = slot;
      c.to = pose(id, slot);
      const z = 100 - slot;
      if (was !== null && was !== slot && !reduced()
        && ((dir < 0 && was === 0) || (dir > 0 && slot === 0 && was > 0))) {
        // Cards you've been through go round the left. The one leaving the top
        // swings out that way and tucks in under the pile; the one coming back
        // swings out from under it and drops on top. Neither cuts through the pile.
        c.via = { x: -w * 1.12, zOut: was === 0 ? 101 : 50, zIn: z };
      } else if (c.via) c.via.zIn = z;
      else c.z = z;
      c.el.inert = slot !== 0;
      c.el.style.pointerEvents = slot === 0 ? '' : 'none';
      c.el.setAttribute('aria-hidden', slot === 0 ? 'false' : 'true');
    }
    this.kick();
  }

  // Balatro's "juice": a quick swell and wiggle when an answer lands.
  pop() {
    const c = this.cards.get(this.top);
    if (!c || reduced()) return;
    c.vel.s += 2.6;
    c.vel.r += (Math.random() < 0.5 ? -1 : 1) * 60;
    this.kick();
  }

  // Cards behind the top, deepest first; the deepest is the one a right swipe brings back.
  deepest() {
    let best = null;
    for (const [id, c] of this.cards) if (c.slot > 0 && (!best || c.slot > best.slot)) best = c;
    return best;
  }

  listen(id, el) {
    const down = e => {
      if (id !== this.top || e.button > 0) return;
      this.drag = { id, x0: e.clientX, y0: e.clientY, dx: 0, dy: 0, on: false, samples: [[e.timeStamp, e.clientX]] };
    };
    const move = e => {
      if (e.pointerType === 'mouse' && !this.drag && id === this.top && !reduced()) {
        const b = el.getBoundingClientRect();
        this.hover = { px: (e.clientX - b.left) / b.width - 0.5, py: (e.clientY - b.top) / b.height - 0.5 };
        this.kick();
      }
      const d = this.drag;
      if (!d || d.id !== id) return;
      d.dx = e.clientX - d.x0; d.dy = e.clientY - d.y0;
      if (!d.on) {
        if (Math.abs(d.dy) > 10 && Math.abs(d.dy) > Math.abs(d.dx)) { this.drag = null; return; } // a scroll, not a swipe
        if (Math.abs(d.dx) < 10) return;
        d.on = true; // only now does it count as a drag, so taps still vote
        el.setPointerCapture?.(e.pointerId);
        el.classList.add('lifted');
        this.hover = null;
      }
      d.samples.push([e.timeStamp, e.clientX]);
      if (d.samples.length > 5) d.samples.shift();
      this.kick();
    };
    const up = e => {
      const d = this.drag;
      if (!d || d.id !== id) return;
      this.drag = null;
      el.classList.remove('lifted');
      this.kick();
      if (!d.on) return;
      // Swallow the click that ends a drag, so a swipe never votes by accident.
      const eat = ev => { ev.stopPropagation(); ev.preventDefault(); };
      el.addEventListener('click', eat, { capture: true, once: true });
      setTimeout(() => el.removeEventListener('click', eat, { capture: true }), 0);
      const [t0, x0] = d.samples[0], [t1, x1] = d.samples[d.samples.length - 1];
      const vx = t1 > t0 ? ((x1 - x0) / (t1 - t0)) * 1000 : 0; // px per second
      const c = this.cards.get(id);
      if (c) c.vel.x = clamp(vx, -4000, 4000);
      const flung = Math.abs(vx) > 600 && Math.sign(vx) === Math.sign(d.dx);
      if (e.type !== 'pointercancel' && this.opts.can && (Math.abs(d.dx) > this.width() * 0.28 || flung)) {
        this.dir = d.dx < 0 ? -1 : 1;
        this.opts.swipe(this.dir);
      }
    };
    const leave = () => { if (this.hover) { this.hover = null; this.kick(); } };
    const evs = { pointerdown: down, pointermove: move, pointerup: up, pointercancel: up, pointerleave: leave };
    for (const k in evs) el.addEventListener(k, evs[k]);
    return () => { for (const k in evs) el.removeEventListener(k, evs[k]); };
  }

  kick() {
    if (!this.raf) { this.last = performance.now(); this.raf = requestAnimationFrame(this.tick); }
  }

  step(c, to, dt, skip) {
    const calm = reduced();
    let busy = false;
    const n = 4, h = dt / n; // small steps keep stiff springs steady on slow frames
    for (const key of KEYS) {
      if (skip && (key === 'x' || key === 'y')) continue;
      const sp = calm ? CALM : SPRING[SPRING_OF[key]];
      for (let i = 0; i < n; i++) {
        c.vel[key] += (sp.k * (to[key] - c.v[key]) - sp.c * c.vel[key]) * h;
        c.v[key] += c.vel[key] * h;
      }
      const eps = key === 'x' || key === 'y' ? 0.3 : key === 's' ? 0.0005 : 0.02;
      if (Math.abs(to[key] - c.v[key]) > eps || Math.abs(c.vel[key]) > eps * 8) busy = true;
      else if (!skip) { c.v[key] = to[key]; c.vel[key] = 0; }
    }
    return busy;
  }

  tick(now) {
    this.raf = 0;
    const dt = Math.min((now - this.last) / 1000, 1 / 24);
    this.last = now;
    let busy = false;
    const w = this.width();
    const d = this.drag && this.drag.on ? this.drag : null;
    const can = this.opts.can;
    const pull = d ? (can ? d.dx : d.dx * 0.3) : 0; // with nowhere to go, a drag is rubbery
    const peek = d && can && pull > 0 ? this.deepest() : null;

    for (const [id, c] of this.cards) {
      if (c.delay > 0) { c.delay -= dt * 1000; busy = true; continue; }
      const to = { ...c.to };
      const held = d && d.id === id;

      if (c.via) {
        to.x = c.via.x; to.y = 0; to.r = -12; to.s = 1;
        if (c.v.x < c.via.x * 0.8) { c.z = c.via.zIn; c.via = null; } else c.z = c.via.zOut;
        busy = true;
      } else if (held) {
        // The card follows the finger exactly and leans with its speed, like it's being carried.
        const px = c.v.x;
        c.v.x = pull; c.v.y = d.dy * 0.1;
        c.vel.x = dt > 0 ? (pull - px) / dt : 0; c.vel.y = 0;
        to.r = pull / 26 + clamp(c.vel.x / 140, -12, 12);
        to.ry = clamp(pull / 14, -16, 16);
        to.s = 1.02;
        busy = true;
      } else if (c === peek) {
        // Pulling right slides the card that's coming back out from under the left edge.
        const t = clamp(pull / (w * 0.6), 0, 1);
        to.x = c.to.x - t * w * 0.55; to.r = c.to.r - t * 8;
        busy = true;
      } else if (id === this.top && this.hover) {
        to.rx = -this.hover.py * 9; to.ry = this.hover.px * 11;
        busy = true;
      }
      if (this.step(c, to, dt, held)) busy = true;
      this.write(c);
    }

    for (const g of this.ghosts) {
      if (g.delay > 0) { g.delay -= dt * 1000; busy = true; continue; }
      this.step(g, g.to, dt, false);
      this.write(g);
      if (g.v.x > w * 1.1) { g.el.remove(); this.ghosts.delete(g); } else busy = true;
    }

    if (busy || this.drag) this.raf = requestAnimationFrame(this.tick);
  }

  write(c) {
    const { x, y, r, s, rx, ry } = c.v;
    const still = !x && !y && !r && s === 1 && !rx && !ry;
    // No transform at rest, so the browser draws the text sharp again.
    c.el.style.transform = still ? '' : (rx || ry
      ? `perspective(900px) translate3d(${x.toFixed(2)}px,${y.toFixed(2)}px,0) rotate(${r.toFixed(3)}deg) rotateX(${rx.toFixed(2)}deg) rotateY(${ry.toFixed(2)}deg) scale(${s.toFixed(4)})`
      : `translate3d(${x.toFixed(2)}px,${y.toFixed(2)}px,0) rotate(${r.toFixed(3)}deg) scale(${s.toFixed(4)})`);
    c.el.style.zIndex = c.z;
  }

  destroy() {
    cancelAnimationFrame(this.raf);
    this.raf = 0;
    for (const c of this.cards.values()) c.off();
    for (const g of this.ghosts) g.el.remove();
    this.ghosts.clear();
  }
}

// Drives a stack of cards. slots maps each card's id to its place (0 on top).
// onSwipe(dir) is called with -1 for a swipe left and 1 for a swipe right;
// can says whether there's anywhere to swipe to. pop changes when the top card
// is answered. Call dir(-1) or dir(1) before moving the stack any other way
// (buttons, keys), so cards go round the correct side.
export function useDeckMotion({ slots, onSwipe, can, pop }) {
  const ref = useRef(null);
  if (!ref.current) ref.current = new DeckMotion();
  const motion = ref.current;
  motion.opts = { swipe: onSwipe, can };

  const refs = useRef(new Map());
  const cardRef = useCallback(id => {
    if (!refs.current.has(id)) refs.current.set(id, el => motion.register(id, el));
    return refs.current.get(id);
  }, [motion]);

  const key = JSON.stringify(slots);
  useLayoutEffect(() => { motion.layout(slots); }, [key]);

  const lastPop = useRef(pop);
  useEffect(() => {
    if (pop > lastPop.current) motion.pop();
    lastPop.current = pop;
  }, [pop]);

  useEffect(() => () => motion.destroy(), [motion]);

  return { cardRef, dir: useCallback(v => { motion.dir = v; }, [motion]) };
}
