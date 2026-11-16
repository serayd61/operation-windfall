/* Operation Windfall match server: one Durable Object per 4 v 4 room (an open match, a squadron's, or a campaign chapter).
   The room owns the sides, the bots, every aircraft's health, the score and the clock.
   A client only reports where it is and what it thinks it hit; the room decides whether that counts. */
import { DurableObject } from 'cloudflare:workers';

const HZ = 15, GOAL = 25, CAP = 300, SEATS = 4, MAXH = SEATS * 2;
const ZONES = [[-1000, 500], [0, -700], [1000, 500]], ZR = 380, ZGOAL = 100; // zone control: three rings in the air, a point every 3 s each, 2 a kill; the first is the airfield (rearm and repair), the second the radar (half the wait to fly again), the third the harbour (double pay)
const SHIPX = 1900, SHIP_HP = 1600, SHIP_CAP = 420, BOMB = 130, RKT = 35; // carrier strike: sink the other side's carrier with bombs and rockets
const AMB_MAX = 8, AMR_MAX = 16; // the most bombs and rockets rewards can stack up to
const LPTS = [[-420, 220], [0, -100], [420, 220]], LR = 95, LGOAL = 200, LAND_CAP = 420, LBEACH = [[-560, 760], [560, 760]]; // island assault: three strongpoints on the island, a beach a side
const GU = [{ hp: 60, sp: 11, rng: 140, dps: [6, 1.5], n: 5 }, { hp: 220, sp: 9, rng: 220, dps: [14, 24], n: 2 }]; // the ground units: rifle squads and tanks
const SKIES = ['day', 'day', 'dusk', 'night', 'storm']; // each match draws its weather
const BOT_HP = 45, BOT_NAMES = [['Dusty', 'Mac', 'Sparks', 'Lucky', 'Tex'], ['Falke', 'Adler', 'Wolf', 'Habicht', 'Luchs']];
/* the campaign: twenty chapters on four fronts. Each is one of the four modes under a fixed sky, flown by the pilots against bots, with a rule or two of its own:
   goal and cap replace the mode's own; bhp and bacc make the other side's bots tougher and straighter; ship scales their carrier; load scales the bombs and rockets a pilot carries;
   tanks adds to their armour; flak scales their guns; short takes a wingman from our side; zpay scales what a ring pays; resp is how long a pilot waits to fly again */
const CH = [null,
  { mode: 'df', wx: 'day', goal: 15 }, { mode: 'zone', wx: 'day' }, { mode: 'ship', wx: 'day', ship: .5 }, { mode: 'land', wx: 'dusk' }, { mode: 'ship', wx: 'storm', bhp: 1.5 },
  { mode: 'df', wx: 'dusk', goal: 30 }, { mode: 'zone', wx: 'storm', zpay: 1.5 }, { mode: 'land', wx: 'day', tanks: 1 }, { mode: 'df', wx: 'night', load: [0, 0] }, { mode: 'land', wx: 'night', flak: 2 },
  { mode: 'ship', wx: 'dusk', load: [0, 1] }, { mode: 'zone', wx: 'day', bacc: 1.5 }, { mode: 'land', wx: 'storm', noRearm: 1 }, { mode: 'df', wx: 'storm', resp: 8 }, { mode: 'ship', wx: 'night', cap: 300, bhp: 1.3 },
  { mode: 'land', wx: 'day', tanks: 2 }, { mode: 'zone', wx: 'night', short: 1 }, { mode: 'df', wx: 'storm', goal: 35, bhp: 1.6, bacc: 1.4 }, { mode: 'ship', wx: 'storm', load: [.5, 1] }, { mode: 'land', wx: 'night', goal: 250, tanks: 1, bhp: 1.5, bacc: 1.3, flak: 1.5 },
];
/* what a pilot flies as: a fighter hits aircraft harder; an attacker carries the rockets, shrugs off some fire and is the one for troops; a bomber carries the bombs and the plate.
   ld is the bombs and rockets it takes off with, gun what its guns do to aircraft, gg to ground units, bomb and rkt what its ordnance does, arm how much of a hit gets through */
const ROLE = { f: { ld: [0, 4], gun: 1.15, gg: .8, bomb: 1, rkt: 1, arm: 1 }, a: { ld: [2, 14], gun: 1, gg: 1.3, bomb: 1, rkt: 1.25, arm: .85 }, b: { ld: [8, 4], gun: .9, gg: 1, bomb: 1.3, rkt: 1, arm: .7 } }, ROLE0 = { gun: 1, gg: 1, bomb: 1, rkt: 1, arm: 1 };
const PI = Math.PI;
const rnd = (a, b) => a + Math.random() * (b - a);
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const num = v => typeof v === 'number' && isFinite(v);
const wrap = a => { while (a > PI) a -= 2 * PI; while (a < -PI) a += 2 * PI; return a; };
const r1 = v => Math.round(v * 10) / 10, r3 = v => Math.round(v * 1000) / 1000;

export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    if (u.pathname === '/stats') return env.LOBBY.get(env.LOBBY.idFromName('lobby')).fetch('https://lobby/stats');
    if (u.pathname !== '/ws') return new Response('windfall-match ok', { headers: { 'content-type': 'text/plain' } });
    if (req.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const room = (u.searchParams.get('room') || 'open').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 24) || 'open';
    const n = clamp(parseInt(u.searchParams.get('n')) || 0, 0, 15);
    const q = u.searchParams.get('mode'), ch = clamp(parseInt(u.searchParams.get('ch')) || 0, 0, CH.length - 1), mode = ch ? 'ch' + ch + '#' : q === 'zone' ? 'zone#' : q === 'ship' ? 'ship#' : q === 'land' ? 'land#' : '';
    return env.MATCH.get(env.MATCH.idFromName(room + '#' + mode + n)).fetch(req);
  },
};

/* how many pilots are flying each mode right now: every room reports its head count here */
export class Lobby extends DurableObject {
  constructor(ctx, env) { super(ctx, env); this.rooms = new Map(); }
  async fetch(req) {
    const now = Date.now();
    if (req.method === 'POST') { try { const m = await req.json(); if (m.n > 0) this.rooms.set(String(m.key), { mode: m.mode, n: m.n | 0, t: now }); else this.rooms.delete(String(m.key)); } catch (e) {} return new Response('ok'); }
    const out = { df: 0, zone: 0, ship: 0, land: 0 }; for (const [k, r] of this.rooms) { if (now - r.t > 150000) this.rooms.delete(k); else if (r.mode in out) out[r.mode] += r.n; }
    return new Response(JSON.stringify(out), { headers: { 'content-type': 'application/json', 'access-control-allow-origin': '*', 'cache-control': 'max-age=5' } });
  }
}

export class Match extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.conns = new Set(); this.ents = new Map(); this.timer = null; this.c = null;
    this.sc = [0, 0]; this.start = 0; this.over = 0; this.last = 0; this.botN = 0; this.dirty = false; this.open = true; this.mode = 'df'; this.scf = [0, 0]; this.zs = ZONES.map(() => ({ v: 0, own: -1 })); this.ships = [SHIP_HP, SHIP_HP];
    this.guns = [{ id: 'ship0', team: 0, kills: 0 }, { id: 'ship1', team: 1, kills: 0 }]; this.key = ''; this.toldT = 0; this.gu = []; this.gid = 0; this.gwT = 0; this.g0 = true; this.bz = null; this.tickN = 0; this.ch = 0; this.R = {};
  }

  tell() { // the head count for the lobby
    this.toldT = Date.now(); if (!this.key) return;
    this.ctx.waitUntil(this.env.LOBBY.get(this.env.LOBBY.idFromName('lobby')).fetch('https://lobby/set', { method: 'POST', body: JSON.stringify({ key: this.key, mode: this.mode, n: this.humans() }) }).catch(() => {}));
  }

  async fetch(req) {
    try { const u = new URL(req.url); this.key = (u.searchParams.get('room') || 'open') + '#' + (u.searchParams.get('mode') || 'df') + '#' + (u.searchParams.get('n') || 0); } catch (e) {}
    try { this.open = (new URL(req.url).searchParams.get('room') || 'open').toLowerCase().replace(/[^a-z0-9]/g, '') in { open: 1, '': 1 }; if (!this.humans()) { const u = new URL(req.url), q = u.searchParams.get('mode'); this.ch = clamp(parseInt(u.searchParams.get('ch')) || 0, 0, CH.length - 1); this.R = CH[this.ch] || {}; this.mode = this.R.mode || (q === 'zone' || q === 'ship' || q === 'land' ? q : 'df'); } if (this.ch) { this.open = false; this.key = ''; } } catch (e) {}
    const pair = new WebSocketPair(), ws = pair[1]; ws.accept();
    const conn = { ws, ent: null, busy: false, at: Date.now() }; this.conns.add(conn);
    ws.addEventListener('message', ev => { try { this.got(conn, ev.data); } catch (e) {} });
    const gone = () => this.drop(conn); ws.addEventListener('close', gone); ws.addEventListener('error', gone);
    if (!this.timer) { this.last = Date.now(); this.timer = setInterval(() => { try { this.tick(); } catch (e) {} }, 1000 / HZ); }
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  send(conn, m) { try { conn.ws.send(JSON.stringify(m)); } catch (e) {} }
  all(m) { const s = JSON.stringify(m); for (const c of this.conns) if (c.ent) try { c.ws.send(s); } catch (e) {} }
  humans() { let n = 0; for (const e of this.ents.values()) if (!e.bot) n++; return n; }

  drop(conn) {
    if (!this.conns.delete(conn)) return; try { conn.ws.close(1000, 'bye'); } catch (e) {}
    if (conn.ent && conn.ent.conn === conn) { this.ents.delete(conn.ent.id); this.fill(); this.tell(); }
    if (!this.conns.size) this.shut();
  }
  shut() { clearInterval(this.timer); this.timer = null; this.ents.clear(); this.zero(); this.sc = [0, 0]; this.start = 0; this.over = 0; this.c = null; this.bz = null; }

  zero() { this.wx = this.R.wx || SKIES[Math.floor(Math.random() * SKIES.length)]; this.scf = [0, 0]; for (const z of this.zs) { z.v = 0; z.own = -1; } this.ships = [this.smax(0), this.smax(1)]; if (this.mode === 'ship') this.sc = [100, 100]; this.gu = []; this.gwT = 0; this.g0 = true; }
  cap() { return this.R.cap || (this.mode === 'ship' ? SHIP_CAP : this.mode === 'land' ? LAND_CAP : CAP); }
  smax(team) { return Math.round(SHIP_HP * (team === 1 && this.R.ship || 1)); } // a chapter may give their carrier thinner or thicker plate
  rk(e) { return !e.bot && ROLE[e.rl] || ROLE0; }
  hp0(e) { return e.bot ? Math.round(BOT_HP * (e.team === 1 && this.R.bhp || 1)) : 100; }
  ld(e) { const L = !e.bot && this.R.load || [1, 1]; return [Math.floor((e.b0 == null ? 4 : e.b0) * L[0]), Math.floor((e.r0 == null ? 10 : e.r0) * L[1])]; } // the bombs and rockets this aircraft takes off with
  spos(team) { const c = this.c || [0, -1900]; return [c[0] + (team ? SHIPX : -SHIPX), c[1]]; }
  near(e, team) { const p = this.spos(team); return Math.hypot(e.p[0] - p[0], e.p[2] - p[1]); }
  arm(e, keep) { const [b, r] = this.ld(e); e.amb = keep ? Math.max(e.amb || 0, b) : b; e.amr = keep ? Math.max(e.amr || 0, r) : r; e.armed = true; e.armAt = Date.now(); } // a rearm over the beach or the carrier keeps what was earned; a new aircraft starts with the plain load
  reward(e, k) { // a pilot earns ordnance: three bombs for a tank, two rockets for a squad, four rockets and a patch-up for an aircraft
    if (!e || e.bot || !e.alive || !e.conn || this.over) return; const b0 = e.amb, r0 = e.amr, h0 = e.hp;
    const L = this.R.load || [1, 1]; /* a chapter that takes the bombs away pays a tank in rockets; one that takes both pays in repairs alone */
    if (k === 'tank') { if (L[0]) e.amb = Math.min(AMB_MAX, e.amb + 3); else if (L[1]) e.amr = Math.min(AMR_MAX, e.amr + 3); } else if (k === 'squad') { if (L[1]) e.amr = Math.min(AMR_MAX, e.amr + 2); } else { if (L[1]) e.amr = Math.min(AMR_MAX, e.amr + 4); e.hp = Math.min(100, e.hp + 25); }
    this.send(e.conn, { t: 'rw', k, b: e.amb - b0, r: e.amr - r0, hp: e.hp > h0 ? r1(e.hp) : undefined });
  }
  shipHurt(team, d, by, k) { // a bomb or rocket found the carrier
    if (this.over || this.ships[team] <= 0) return; this.ships[team] = Math.max(0, this.ships[team] - d);
    this.sc[team] = Math.ceil(this.ships[team] / this.smax(team) * 100); if (by && by.team !== team) { by.sd = (by.sd || 0) + d; while (by.sd >= 260) { by.sd -= 260; by.kills++; } } /* damage to the carrier counts like kills */
    this.all({ t: 'sh', s: team, hp: this.ships[team], k, by: by ? by.id : '' });
  }
  goal() { return this.R.goal || (this.mode === 'zone' ? ZGOAL : this.mode === 'land' ? LGOAL : GOAL); }
  zpos(i) { const c = this.c || [0, -1900], Z = this.mode === 'land' ? LPTS : ZONES; return [c[0] + Z[i][0], c[1] + Z[i][1]]; }
  bpos(team) { if (this.bz) return this.bz[team]; const c = this.c || [0, -1900]; return [c[0] + LBEACH[team][0], c[1] + LBEACH[team][1]]; }

  /* island assault: the ground war runs here, flat on the map; every client sets the units on its own terrain */
  ggoal(u) { // the nearest strongpoint that is not ours yet; failing that, the one of ours most under threat
    let best = 1e9; for (let i = 0; i < LPTS.length; i++) { const p = this.zpos(i), z = this.zs[i], d = Math.hypot(p[0] - u.x, p[1] - u.z) + u.bias[i] + (z.own === u.team ? 900 - (u.team ? 1 - z.v : 1 + z.v) * 600 : 0); if (d < best) { best = d; u.goal = i; } }
  }
  gspawn(team, kind, adv) {
    const b = this.bpos(team), u = { id: ++this.gid, team, kind, x: b[0] + rnd(-40, 40), z: b[1] + rnd(-25, 25), hp: GU[kind].hp, goal: 0, ox: rnd(-70, 70), oz: rnd(-70, 70), bias: [rnd(0, 480), rnd(0, 480), rnd(0, 480)], reT: rnd(0, 1), f: 0, tg: null, dead: false };
    this.ggoal(u); if (adv) { const g = this.zpos(u.goal); u.x += (g[0] - u.x) * adv + rnd(-80, 80); u.z += (g[1] - u.z) * adv + rnd(-80, 80); }
    this.gu.push(u);
  }
  gdead(u, by) {
    if (u.dead) return; u.dead = true; u.hp = 0; this.scf[1 - u.team] += (u.kind ? 1 : .5) * (by && by.team !== u.team ? (by.bot ? 2 : 4) : 1); /* troops killing troops pay half of what they did; a bot's strafing pays double that, a pilot's four times */ this.sc[1 - u.team] = Math.floor(this.scf[1 - u.team]);
    if (by && by.team !== u.team) { by.gk = (by.gk || 0) + (u.kind ? 1 : .5); while (by.gk >= 1) { by.gk -= 1; by.kills++; } this.reward(by, u.kind ? 'tank' : 'squad'); } // a tank counts as a kill, a squad as half of one
    this.all({ t: 'gk', i: u.id, by: by ? by.id : '', sc: this.sc });
  }
  ghurt(u, d, by) { if (u.hp <= 0 || this.over) return; u.hp -= d; if (u.hp <= 0) this.gdead(u, by); }
  ground(dt) {
    this.gwT -= dt;
    if (this.gwT <= 0) { // the next wave comes ashore
      this.gwT = 15; const first = this.g0; this.g0 = false;
      for (let team = 0; team < 2; team++) for (let kind = 0; kind < 2; kind++) { let n = 0, add = 0; for (const u of this.gu) if (u.team === team && u.kind === kind && u.hp > 0) n++; for (; n < GU[kind].n + (team === 1 && kind === 1 && this.R.tanks || 0) && add < (kind ? 1 : first ? 4 : 3); n++, add++) this.gspawn(team, kind, first ? .55 : 0); }
    }
    for (const u of this.gu) {
      if (u.hp <= 0) continue; const K = GU[u.kind]; u.reT -= dt;
      if (u.reT <= 0) { u.reT = rnd(.8, 1.3); this.ggoal(u); u.tg = null; let best = K.rng; for (const v of this.gu) if (v.team !== u.team && v.hp > 0) { const d = Math.hypot(v.x - u.x, v.z - u.z); if (d < best) { best = d; u.tg = v; } } }
      const t = u.tg;
      if (t && t.hp > 0) { u.f = t.id; t.hp -= K.dps[t.kind] * dt; if (t.hp <= 0) this.gdead(t, null); continue; }
      u.f = 0; u.tg = null; const g = this.zpos(u.goal), dx = g[0] + u.ox - u.x, dz = g[1] + u.oz - u.z, d = Math.hypot(dx, dz);
      if (d > 6) { const s = Math.min(d, K.sp * dt); u.x += dx / d * s; u.z += dz / d * s; }
    }
    if (this.gu.some(u => u.hp <= 0)) this.gu = this.gu.filter(u => u.hp > 0);
  }

  async pilot(tok, dev) {
    if (this.env.DEV_OPEN === '1' && typeof dev === 'string') return { id: 'dev-' + dev, name: dev };
    if (typeof tok !== 'string' || tok.length < 20 || tok.length > 4000) return null;
    const r = await fetch(this.env.SUPABASE_URL + '/rest/v1/rpc/my_pilot', { method: 'POST', body: '{}',
      headers: { apikey: this.env.SUPABASE_KEY, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' } });
    if (!r.ok) return null; const p = await r.json(); return p && p.id && !p.banned ? p : null;
  }

  async got(conn, raw) {
    if (typeof raw !== 'string' || raw.length > (conn.ent ? 700 : 6000)) return; /* only the first message carries the sign-in token */ const m = JSON.parse(raw); if (!m || typeof m !== 'object') return;
    const e = conn.ent;
    if (!e) {
      if (m.t !== 'hi' || conn.busy) return; conn.busy = true;
      let p = null; try { p = await this.pilot(m.tok, m.dev); } catch (err) {}
      if (!this.conns.has(conn)) return;
      if (!p) { this.send(conn, { t: 'no', why: 'auth' }); return this.drop(conn); }
      const old = this.ents.get(p.id);
      if (old) { const oc = old.conn; this.ents.delete(p.id); old.conn = null; if (oc) { oc.ent = null; this.drop(oc); } }
      if (this.humans() >= (this.ch ? SEATS - (this.R.short || 0) : MAXH)) { this.send(conn, { t: 'full' }); return this.drop(conn); }
      if (!this.c && this.mode === 'land' && Array.isArray(m.g) && m.g.length === 4 && m.g.every(num) && Array.isArray(m.c) && m.c.length === 2 && m.c.every(num) && Math.hypot(m.g[0] - m.c[0], m.g[1] - m.c[1]) < 1600 && Math.hypot(m.g[2] - m.c[0], m.g[3] - m.c[1]) < 1600) this.bz = [[m.g[0], m.g[1]], [m.g[2], m.g[3]]];
      if (!this.c) this.c = Array.isArray(m.c) && m.c.length === 2 && m.c.every(num) ? [clamp(m.c[0], -6000, 6000), clamp(m.c[1], -6000, 6000)] : [0, -1900];
      const cnt = [0, 0]; for (const x of this.ents.values()) if (!x.bot) cnt[x.team]++;
      const team = this.ch ? 0 : !this.open ? (cnt[0] < SEATS ? 0 : 1) : cnt[0] < cnt[1] ? 0 : cnt[1] < cnt[0] ? 1 : this.sc[1] < this.sc[0] ? 1 : 0;
      const ent = this.make(p.id, String(p.name || 'Pilot').replace(/[<>&]/g, '').slice(0, 16), team, false);
      ent.k = Number.isInteger(m.k) ? clamp(m.k, 0, 31) : 0; if (typeof m.r === 'string' && ROLE[m.r]) { ent.rl = m.r; ent.b0 = ROLE[m.r].ld[0]; ent.r0 = ROLE[m.r].ld[1]; this.arm(ent); } else if (Array.isArray(m.a) && m.a.length === 2 && m.a.every(Number.isInteger)) { ent.b0 = clamp(m.a[0], 0, 4); ent.r0 = clamp(m.a[1], 0, 10); this.arm(ent); } ent.conn = conn; ent.uid = p.id; ent.since = Date.now(); ent.fresh = false; conn.ent = ent;
      if (!this.start) { this.start = Date.now(); this.sc = [0, 0]; this.zero(); this.over = 0; }
      this.fill(); this.tell();
      this.send(conn, { t: 'in', id: ent.id, team, goal: this.goal(), seats: SEATS, mode: this.mode, wx: this.wx, rl: ent.rl, am: this.ld(ent), ch: this.ch || undefined, ld: this.R.load, bhp: this.R.bhp, sp: this.mode === 'ship' ? [this.spos(0), this.spos(1)] : undefined, shp: SHIP_HP, shm: this.mode === 'ship' ? [this.smax(0), this.smax(1)] : undefined, zp: this.mode === 'zone' ? ZONES.map((z, i) => [...this.zpos(i), ZR]) : this.mode === 'land' ? LPTS.map((z, i) => [...this.zpos(i), LR]) : undefined, bz: this.mode === 'land' ? [this.bpos(0), this.bpos(1)] : undefined, left: this.left(), sc: this.sc, c: this.c });
      return;
    }
    e.seen = Date.now();
    if (m.t === 'p') {
      if (!Array.isArray(m.p) || !Array.isArray(m.q) || m.p.length !== 3 || m.q.length !== 4 || !m.p.every(num) || !m.q.every(num)) return;
      if (!e.alive || !m.a) return;
      const now = Date.now(), gap = (now - e.pt) / 1000, x = clamp(m.p[0], -9000, 9000), y = clamp(m.p[1], 0, 4000), z = clamp(m.p[2], -9000, 9000);
      if (e.fresh && gap > .03 && gap < 1) { e.vel[0] = (x - e.p[0]) / gap; e.vel[1] = (y - e.p[1]) / gap; e.vel[2] = (z - e.p[2]) / gap; }
      e.p[0] = x; e.p[1] = y; e.p[2] = z; e.pt = now; e.fresh = true;
      const l = Math.hypot(m.q[0], m.q[1], m.q[2], m.q[3]) || 1; for (let i = 0; i < 4; i++) e.q[i] = m.q[i] / l;
      e.f = m.f ? 1 : 0;
    } else if (m.t === 'h') { this.claim(e, m);
    } else if (m.t === 'g') { // guns on a ground unit: squads suffer, armour shrugs most of it off
      if (this.mode !== 'land' || !e.alive || !e.fresh || this.over || !num(m.d) || m.d <= 0) return;
      const u = this.gu.find(x => x.id === m.i); if (!u || u.hp <= 0 || u.team === e.team || Math.hypot(u.x - e.p[0], u.z - e.p[2]) > 800) return;
      const d = Math.min(m.d, e.budget); if (d <= 0) return; e.budget -= d; this.ghurt(u, (u.kind ? d * .2 : d * .6) * this.rk(e).gg, e);
    } else if (m.t === 'b' && this.mode === 'land') { // a bomb or rocket came down on the island: whoever of the other side stood near it
      if (!e.alive || !e.fresh || this.over || !num(m.x) || !num(m.z) || Math.hypot(m.x - e.p[0], m.z - e.p[2]) > 1500) return;
      const rk = m.k === 1; if (rk ? e.amr <= 0 : e.amb <= 0) return; if (rk) e.amr--; else e.amb--;
      const R = rk ? 30 : 48, D = rk ? 140 * this.rk(e).rkt : 280 * this.rk(e).bomb; for (const u of this.gu) { if (u.team === e.team || u.hp <= 0) continue; const d = Math.hypot(u.x - m.x, u.z - m.z); if (d < R) this.ghurt(u, D * (1 - .7 * d / R), e); }
    } else if (m.t === 'b') { // ordnance on the enemy carrier: only what this aircraft still carries, and only from nearby
      if (this.mode !== 'ship' || !e.alive || !e.fresh || this.over || this.near(e, 1 - e.team) > 1200) return;
      if (m.k === 1) { if (e.amr <= 0) return; e.amr--; this.shipHurt(1 - e.team, RKT * this.rk(e).rkt, e, 1); } else { if (e.amb <= 0) return; e.amb--; this.shipHurt(1 - e.team, BOMB * this.rk(e).bomb, e, 0); }
    } else if (m.t === 'x') { if (e.alive) this.kill(e, Date.now() - e.hitAt < 6000 ? this.ents.get(e.hitBy) : null); }
  }

  /* a client says its guns found someone: believe it only if the shot was possible */
  claim(e, m) {
    const t = this.ents.get(m.to); if (!t || !e.alive || !e.fresh || !t.alive || t.team === e.team || this.over || !num(m.d) || m.d <= 0) return;
    const d = Math.min(m.d, e.budget); if (d <= 0) return;
    const dx = t.p[0] - e.p[0], dy = t.p[1] - e.p[1], dz = t.p[2] - e.p[2], dist = Math.hypot(dx, dy, dz); if (dist > 750) return;
    const q = e.q, fx = -2 * (q[0] * q[2] + q[3] * q[1]), fy = -2 * (q[1] * q[2] - q[3] * q[0]), fz = -(1 - 2 * (q[0] * q[0] + q[1] * q[1]));
    if (dist > 40 && (fx * dx + fy * dy + fz * dz) / dist < .8) return;
    e.budget -= d; this.hurt(t, (t.bot ? d : d * .5) * this.rk(e).gun, e);
  }

  hurt(t, d, by) {
    if (Date.now() < t.safe) return;
    t.hp -= d * this.rk(t).arm; t.hitAt = Date.now(); t.hitBy = by.id;
    if (t.bot) { if (Math.random() < .3) this.evade(t); } else if (t.conn) this.send(t.conn, { t: 'd', hp: Math.max(0, r1(t.hp)), by: by.id });
    if (t.hp <= 0) this.kill(t, by);
  }

  kill(v, by) {
    if (!v.alive || this.over) return; v.alive = false; v.hp = 0; v.f = 0; v.deaths++; v.fresh = false; v.resp = (v.bot ? 4 : this.R.resp || 3.2) * (this.mode === 'zone' && this.zs[1].own === v.team ? .5 : 1); // the side that holds the radar is back in the air in half the time
    if (this.mode === 'zone' || this.mode === 'land') { this.scf[1 - v.team] += this.mode === 'zone' ? 2 : 1; this.sc[1 - v.team] = Math.floor(this.scf[1 - v.team]); } else if (this.mode !== 'ship') this.sc[1 - v.team]++;
    if (by && by.team !== v.team) { by.kills++; if (this.mode === 'land' || this.mode === 'ship') this.reward(by, 'air'); }
    this.all({ t: 'k', i: v.id, by: by ? by.id : '', sc: this.sc });
  }

  left() { return this.start ? Math.max(0, Math.round(this.cap() - (Date.now() - this.start) / 1000)) : this.cap(); }

  make(id, name, team, bot) {
    const e = { id, name, team, bot, k: 0, conn: null, alive: true, hp: this.hp0({ bot, team }), p: [0, 0, 0], q: [0, 0, 0, 1], vel: [0, 0, 0], f: 0, kills: 0, deaths: 0,
      resp: 0, zone: -1, safe: Date.now() + 3000, hitAt: 0, hitBy: '', seen: Date.now(), pt: 0, budget: 200, fresh: true, yaw: 0, pitch: 0, roll: 0, v: 80, tgt: null, retT: 0, evT: 0, evYaw: 0, evPitch: 0, amb: 4, amr: 10, armed: true, armAt: Date.now(), role: bot && this.botN % 2 === 0 ? 'atk' : '' };
    this.place(e); this.ents.set(id, e); this.dirty = true; return e;
  }

  place(e) { // air start on the team's side of the field, nose toward the middle
    const side = e.team ? 1 : -1, c = this.c || [0, -1900];
    const land = this.mode === 'land'; e.p[0] = c[0] + side * ((land ? 1300 : 1500) + rnd(0, 300)); e.p[1] = 480 + rnd(-60, 60); e.p[2] = c[1] + (land ? 700 : 0) + rnd(-250, 250);
    e.yaw = side > 0 ? PI / 2 : -PI / 2; e.pitch = 0; e.roll = 0; e.v = 80; e.evT = 0; e.tgt = null; e.retT = 0; e.vel = [0, 0, 0]; this.quat(e);
  }

  /* every side always flies SEATS aircraft: bots hold the seats no pilot has taken */
  fill() {
    this.dirty = true; if (!this.humans()) { for (const [id, e] of this.ents) if (e.bot) this.ents.delete(id); return; }
    for (let team = 0; team < 2; team++) {
      const mine = [...this.ents.values()].filter(e => e.team === team), seats = SEATS - (team === 0 && this.R.short || 0); let n = mine.length;
      for (const b of mine.filter(e => e.bot).sort((a, b) => a.alive - b.alive)) { if (n <= seats) break; this.ents.delete(b.id); n--; }
      for (; n < seats; n++) { const used = mine.map(e => e.name), name = BOT_NAMES[team].find(x => !used.includes(x)) || 'Bandit'; mine.push(this.make('b' + (++this.botN), name, team, true)); }
    }
  }

  quat(e) { // three.js Euler order YXZ: x = pitch, y = yaw, z = roll
    const c1 = Math.cos(e.pitch / 2), c2 = Math.cos(e.yaw / 2), c3 = Math.cos(e.roll / 2), s1 = Math.sin(e.pitch / 2), s2 = Math.sin(e.yaw / 2), s3 = Math.sin(e.roll / 2);
    e.q[0] = s1 * c2 * c3 + c1 * s2 * s3; e.q[1] = c1 * s2 * c3 - s1 * c2 * s3; e.q[2] = c1 * c2 * s3 - s1 * s2 * c3; e.q[3] = c1 * c2 * c3 + s1 * s2 * s3;
  }

  evade(b) { b.evT = rnd(1.8, 3.2); b.evYaw = b.yaw + (Math.random() < .5 ? -1 : 1) * rnd(1.1, 2.4); b.evPitch = rnd(-.2, .4); }

  bot(b, dt) {
    const c = this.c || [0, -1900];
    b.retT -= dt;
    if (b.retT <= 0 || !b.tgt || !b.tgt.alive || !this.ents.has(b.tgt.id)) {
      b.retT = 1.5; b.tgt = null; let best = 1e9;
      for (const t of this.ents.values()) { if (t.team === b.team || !t.alive || !t.fresh) continue; const d = Math.hypot(t.p[0] - b.p[0], t.p[1] - b.p[1], t.p[2] - b.p[2]); if (d < best) { best = d; b.tgt = t; } }
      b.zone = -1; if (this.mode === 'ship' && b.role && best > 320) { b.tgt = null; b.zone = -2; }
      if (this.mode === 'land' && b.role && best > 320) { // nobody on his tail: go for their troops
        let gb = 1e9; b.gt = null; for (const u of this.gu) if (u.team !== b.team && u.hp > 0) { const d = Math.hypot(u.x - b.p[0], u.z - b.p[2]); if (d < gb) { gb = d; b.gt = u; } }
        if (b.gt) { b.tgt = null; b.zone = -3; }
      }
      if (this.mode === 'zone' && best > 520) { // nobody close: head for the nearest ring that is not ours yet, or guard one that is
        b.tgt = null; let zb = 1e9;
        for (let i = 0; i < ZONES.length; i++) { const z = this.zpos(i), d = Math.hypot(z[0] - b.p[0], z[1] - b.p[2]) + (this.zs[i].own === b.team ? 2500 : 0); if (d < zb) { zb = d; b.zone = i; } }
      }
    }
    let wantYaw = b.yaw, wantPitch = 0, dist = 1e9, fire = 0; const t = b.tgt;
    const fx = -Math.sin(b.yaw) * Math.cos(b.pitch), fy = Math.sin(b.pitch), fz = -Math.cos(b.yaw) * Math.cos(b.pitch);
    if (t) {
      let dx = t.p[0] - b.p[0], dy = t.p[1] - b.p[1], dz = t.p[2] - b.p[2]; dist = Math.hypot(dx, dy, dz);
      const lead = Math.min(1.2, dist / 480); dx += t.vel[0] * lead; dy += t.vel[1] * lead; dz += t.vel[2] * lead; const l = Math.hypot(dx, dy, dz) || 1;
      wantYaw = Math.atan2(-dx, -dz); wantPitch = Math.asin(clamp(dy / l, -1, 1));
      if (b.evT <= 0 && dist < 110) this.evade(b);
      if (b.evT <= 0 && !this.over && dist < 520 && (fx * dx + fy * dy + fz * dz) / l > .988) fire = 1;
    }
    if (!t && b.zone >= 0) { const z = this.zpos(b.zone), dx = z[0] - b.p[0], dz = z[1] - b.p[2], dy = 430 - b.p[1], l = Math.hypot(dx, dy, dz) || 1;
      wantYaw = Math.atan2(-dx, -dz); wantPitch = Math.asin(clamp(dy / l, -1, 1)); if (b.evT <= 0 && l < 160) { b.evT = rnd(2.5, 4); b.evYaw = b.yaw + (Math.random() < .5 ? -1 : 1) * rnd(1.6, 2.6); b.evPitch = 0; } }
    if (!t && b.zone === -2) { // a bombing run on their carrier, then home to rearm
      const tm = b.armed ? 1 - b.team : b.team, sp = this.spos(tm), dx = sp[0] - b.p[0], dz = sp[1] - b.p[2], h = Math.hypot(dx, dz), dy = (b.armed ? 240 : 380) - b.p[1];
      wantYaw = Math.atan2(-dx, -dz); wantPitch = Math.asin(clamp(dy / (Math.hypot(h, dy) || 1), -1, 1));
      if (b.evT <= 0 && h < (b.armed ? 170 : 380)) { if (b.armed) { b.armed = false; if (Math.random() < .55) this.shipHurt(tm, BOMB, b, 0); } else b.armed = true; b.evT = rnd(2.5, 4); b.evYaw = b.yaw + rnd(-.5, .5); b.evPitch = .3; }
    }
    if (!t && b.zone === -3) { // a strafing run on a ground unit
      const u = b.gt; if (!u || u.hp <= 0) b.retT = 0; else { const dx = u.x - b.p[0], dz = u.z - b.p[2], h = Math.hypot(dx, dz), dy = 260 - b.p[1];
        wantYaw = Math.atan2(-dx, -dz); wantPitch = Math.asin(clamp(dy / (Math.hypot(h, dy) || 1), -1, 1));
        if (b.evT <= 0 && h < 230) { if (Math.random() < .6) this.ghurt(u, u.kind ? 70 : 30, b); b.evT = rnd(3, 4.5); b.evYaw = b.yaw + rnd(-.6, .6); b.evPitch = .35; } }
    }
    if (b.evT > 0) { b.evT -= dt; wantYaw = b.evYaw; wantPitch = b.evPitch; }
    const hx = b.p[0] - c[0], hz = b.p[2] - c[1]; if (hx * hx + hz * hz > (this.mode === 'land' ? 2600 * 2600 : 3800 * 3800)) { wantYaw = Math.atan2(hx, hz); b.evT = 0; }
    if (b.p[1] < 230) wantPitch = Math.max(wantPitch, .35); else if (b.p[1] > 1100) wantPitch = Math.min(wantPitch, -.2);
    const dyaw = clamp(wrap(wantYaw - b.yaw), -.82 * dt, .82 * dt); b.yaw = wrap(b.yaw + dyaw);
    b.pitch = clamp(b.pitch + clamp(clamp(wantPitch, -.55, .55) - b.pitch, -.6 * dt, .6 * dt), -.55, .55);
    b.roll += (clamp(dyaw / dt * 1.3, -1.1, 1.1) - b.roll) * Math.min(1, 4 * dt);
    b.v += (clamp(82 - b.pitch * 28, 62, 96) - b.v) * Math.min(1, dt);
    const nx = -Math.sin(b.yaw) * Math.cos(b.pitch), ny = Math.sin(b.pitch), nz = -Math.cos(b.yaw) * Math.cos(b.pitch);
    b.vel[0] = nx * b.v; b.vel[1] = ny * b.v; b.vel[2] = nz * b.v; b.p[0] += b.vel[0] * dt; b.p[1] = Math.max(60, b.p[1] + b.vel[1] * dt); b.p[2] += b.vel[2] * dt;
    this.quat(b); b.f = fire;
    if (fire && Math.random() < .5 * (b.team === 1 && this.R.bacc || 1) * (1 - dist / 800)) this.hurt(t, t.bot ? 6 : 4, b);
  }

  tick() {
    const now = Date.now(), dt = clamp((now - this.last) / 1000, .001, .25); this.last = now; this.tickN++;
    for (const c of this.conns) { if (c.ent ? now - c.ent.seen > 10000 : now - c.at > 12000) this.drop(c); }
    if (!this.humans()) return;
    if (now - this.toldT > 60000) this.tell();
    if (this.over) { this.over -= dt; if (this.over <= 0) this.fresh(); }
    for (const e of this.ents.values()) {
      if (!e.alive) { e.resp -= dt; if (e.resp <= 0 && !this.over) { e.alive = true; e.hp = this.hp0(e); e.safe = Date.now() + 3000; this.arm(e); if (e.bot) { this.place(e); e.fresh = true; /* a bot is back the moment it is placed; a pilot once his first position arrives */ } else if (e.conn) this.send(e.conn, { t: 'r' }); } continue; }
      if (e.bot) this.bot(e, dt);
      else { e.budget = Math.min(260, e.budget + 170 * dt); if (now - e.hitAt > 6000 && e.hp < 100) e.hp = Math.min(100, e.hp + 7 * dt); }
    }
    const land = this.mode === 'land';
    if (land && !this.over) { // the ground war, the guns of a held strongpoint, and a rearm over the home beach
      this.ground(dt);
      for (const e of this.ents.values()) {
        if (!e.alive || !e.fresh) continue;
        if (e.p[1] < 520) for (let i = 0; i < LPTS.length; i++) { if (this.zs[i].own !== 1 - e.team) continue; const p = this.zpos(i); if (Math.hypot(e.p[0] - p[0], e.p[2] - p[1]) < 520 && Math.random() < dt * .6 * (e.team === 0 && this.R.flak || 1)) this.hurt(e, e.bot ? 4 : 5, this.guns[1 - e.team]); }
        if (!e.bot && !this.R.noRearm && e.alive && e.p[1] < 700 && now - e.armAt > 15000 && (e.amb < this.ld(e)[0] || e.amr < this.ld(e)[1] || e.hp < 100)) { const b = this.bpos(e.team); if (Math.hypot(e.p[0] - b[0], e.p[2] - b[1]) < 450) { this.arm(e, true); e.hp = 100; if (e.conn) this.send(e.conn, { t: 'arm', hp: 100 }); } }
      }
    }
    if ((this.mode === 'zone' || land) && !this.over) { // who holds each ring or strongpoint, and what it pays
      for (let i = 0; i < ZONES.length; i++) {
        const z = this.zs[i], c = this.zpos(i); let n = [0, 0];
        if (land) { for (const u of this.gu) if (u.hp > 0 && Math.hypot(u.x - c[0], u.z - c[1]) < LR) n[u.team]++; }
        else for (const e of this.ents.values()) if (e.alive && e.fresh && Math.hypot(e.p[0] - c[0], e.p[2] - c[1]) < ZR) n[e.team]++;
        const push = clamp(n[1] - n[0], -3, 3); if (push) z.v = clamp(z.v + push * dt / (land ? 6 : 7), -1, 1);
        if (z.v <= -1) z.own = 0; else if (z.v >= 1) z.own = 1; else if ((z.own === 0 && z.v >= 0) || (z.own === 1 && z.v <= 0)) z.own = -1;
        if (z.own >= 0) { this.scf[z.own] += dt / 3 * (this.R.zpay || 1) * (!land && i === 2 ? 2 : 1); /* the harbour pays double */ this.sc[z.own] = Math.floor(this.scf[z.own]); }
      }
    }
    if (this.mode === 'zone' && !this.over && this.zs[0].own >= 0) { // the airfield rearms and repairs whoever of its holders flies through it
      const c = this.zpos(0), now = Date.now();
      for (const e of this.ents.values()) if (!e.bot && e.alive && e.fresh && e.team === this.zs[0].own && !this.R.noRearm && now - e.armAt > 15000 && (e.amb < this.ld(e)[0] || e.amr < this.ld(e)[1] || e.hp < 100) && Math.hypot(e.p[0] - c[0], e.p[2] - c[1]) < ZR) { this.arm(e, true); e.hp = 100; if (e.conn) this.send(e.conn, { t: 'arm', hp: 100 }); }
    }
    if (this.mode === 'ship' && !this.over) { // each carrier's guns, and a rearm for whoever comes home
      for (const e of this.ents.values()) {
        if (!e.alive || !e.fresh) continue;
        if (e.p[1] < 800 && this.near(e, 1 - e.team) < 800 && Math.random() < dt * 1.1 * (e.team === 0 && this.R.flak || 1)) this.hurt(e, e.bot ? 5 : 6, this.guns[1 - e.team]);
        if (!e.bot && !this.R.noRearm && e.alive && e.p[1] < 700 && now - e.armAt > 15000 && (e.amb < this.ld(e)[0] || e.amr < this.ld(e)[1] || e.hp < 100) && this.near(e, e.team) < 420) { this.arm(e, true); e.hp = 100; if (e.conn) this.send(e.conn, { t: 'arm', hp: 100 }); }
      }
    }
    if (this.dirty) { this.dirty = false; this.all({ t: 'ro', e: [...this.ents.values()].map(e => [e.id, e.name, e.team, e.k, e.bot ? 1 : 0]) }); }
    this.all({ t: 's', l: this.left(), sc: this.sc, z: this.mode === 'zone' || land ? this.zs.map(z => [z.own, r1(z.v)]) : undefined, g: land && this.tickN % 3 === 0 ? this.gu.filter(u => u.hp > 0).map(u => [u.id, u.team, u.kind, Math.round(u.x), Math.round(u.z), Math.round(u.hp), u.f]) : undefined, sh: this.mode === 'ship' ? this.ships : undefined, e: [...this.ents.values()].map(e => [e.id, e.alive && e.fresh ? 1 : 0, r1(e.p[0]), r1(e.p[1]), r1(e.p[2]), r3(e.q[0]), r3(e.q[1]), r3(e.q[2]), r3(e.q[3]), e.f, e.kills, Math.round(e.hp)]) });
    if (!this.over && (this.mode === 'ship' ? this.ships[0] <= 0 || this.ships[1] <= 0 || this.left() <= 0 : this.sc[0] >= this.goal() || this.sc[1] >= this.goal() || this.left() <= 0)) { this.over = this.mode === 'ship' ? 14 : 9; for (const e of this.ents.values()) e.f = 0; this.st = this.stars(); this.all({ t: 'end', sc: this.sc, ch: this.ch || undefined, st: this.ch ? this.st : undefined, tb: [...this.ents.values()].map(e => [e.id, e.name, e.team, e.kills, e.deaths, e.bot ? 1 : 0]) }); this.ctx.waitUntil(this.report().catch(() => {})); }
  }

  /* the result goes to the ranking; only this server knows the key the database asks for */
  /* a chapter's three stars, a pilot at a time: the side won, he was one of its two best, and he was shot down three times at most. A lost chapter pays none */
  stars() {
    const st = {}; if (!this.ch) return st; const won = this.sc[0] > this.sc[1], mine = [...this.ents.values()].filter(e => e.team === 0);
    for (const e of mine) if (!e.bot) st[e.id] = won ? [1, mine.filter(x => x.kills > e.kills).length < 2 ? 1 : 0, e.deaths <= 3 ? 1 : 0] : [0, 0, 0];
    return st;
  }

  async report() {
    if (!this.env.DUEL_KEY) return;
    if (this.ch) { // a chapter is flown against bots: it pays in stars, not in the ranking
      const now = Date.now(), rows = []; for (const e of this.ents.values()) { const s = this.st && this.st[e.id]; if (!e.bot && e.uid && s && s[0] && now - e.since > 60000) rows.push({ id: e.uid, s: s[0] | s[1] << 1 | s[2] << 2 }); }
      if (rows.length) await fetch(this.env.SUPABASE_URL + '/rest/v1/rpc/chapter_report', { method: 'POST', body: JSON.stringify({ p_key: this.env.DUEL_KEY, p_ch: this.ch, p_rows: rows }),
        headers: { apikey: this.env.SUPABASE_KEY, Authorization: 'Bearer ' + this.env.SUPABASE_KEY, 'Content-Type': 'application/json' } });
      return;
    }
    const now = Date.now(), win = this.sc[0] === this.sc[1] ? -1 : this.sc[0] > this.sc[1] ? 0 : 1, rows = [];
    for (const e of this.ents.values()) if (!e.bot && e.uid && (now - e.since > 60000 || e.kills > 0)) rows.push({ id: e.uid, k: e.kills, d: e.deaths, w: e.team === win ? 1 : 0 });
    if (!rows.length) return;
    await fetch(this.env.SUPABASE_URL + '/rest/v1/rpc/duel_report', { method: 'POST', body: JSON.stringify({ p_key: this.env.DUEL_KEY, p_rows: rows }),
      headers: { apikey: this.env.SUPABASE_KEY, Authorization: 'Bearer ' + this.env.SUPABASE_KEY, 'Content-Type': 'application/json' } });
  }

  fresh() { // the next match in the same room
    this.over = 0; this.sc = [0, 0]; this.zero(); this.start = Date.now();
    for (const e of this.ents.values()) { e.kills = 0; e.deaths = 0; e.since = Date.now(); e.alive = true; e.hp = this.hp0(e); e.hitAt = 0; if (e.bot) { this.place(e); e.fresh = true; } else { e.fresh = false; if (e.conn) this.send(e.conn, { t: 'r' }); } }
    this.all({ t: 'new', left: this.cap(), sc: this.sc });
  }
}
