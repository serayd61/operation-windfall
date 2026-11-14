/* Operation Windfall match server: one Durable Object per 2 v 2 room.
   The room owns the sides, the bots, every aircraft's health, the score and the clock.
   A client only reports where it is and what it thinks it hit; the room decides whether that counts. */
import { DurableObject } from 'cloudflare:workers';

const HZ = 15, GOAL = 10, CAP = 480, SEATS = 2, MAXH = SEATS * 2;
const BOT_HP = 45, BOT_NAMES = [['Dusty', 'Mac', 'Sparks'], ['Falke', 'Adler', 'Wolf']];
const PI = Math.PI;
const rnd = (a, b) => a + Math.random() * (b - a);
const clamp = (v, a, b) => (v < a ? a : v > b ? b : v);
const num = v => typeof v === 'number' && isFinite(v);
const wrap = a => { while (a > PI) a -= 2 * PI; while (a < -PI) a += 2 * PI; return a; };
const r1 = v => Math.round(v * 10) / 10, r3 = v => Math.round(v * 1000) / 1000;

export default {
  async fetch(req, env) {
    const u = new URL(req.url);
    if (u.pathname !== '/ws') return new Response('windfall-match ok', { headers: { 'content-type': 'text/plain' } });
    if (req.headers.get('Upgrade') !== 'websocket') return new Response('expected websocket', { status: 426 });
    const room = (u.searchParams.get('room') || 'open').toLowerCase().replace(/[^a-z0-9]/g, '').slice(0, 24) || 'open';
    const n = clamp(parseInt(u.searchParams.get('n')) || 0, 0, 15);
    return env.MATCH.get(env.MATCH.idFromName(room + '#' + n)).fetch(req);
  },
};

export class Match extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    this.conns = new Set(); this.ents = new Map(); this.timer = null; this.c = null;
    this.sc = [0, 0]; this.start = 0; this.over = 0; this.last = 0; this.botN = 0; this.dirty = false;
  }

  async fetch() {
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
    if (conn.ent && conn.ent.conn === conn) { this.ents.delete(conn.ent.id); this.fill(); }
    if (!this.conns.size) this.shut();
  }
  shut() { clearInterval(this.timer); this.timer = null; this.ents.clear(); this.sc = [0, 0]; this.start = 0; this.over = 0; this.c = null; }

  async pilot(tok, dev) {
    if (this.env.DEV_OPEN === '1' && typeof dev === 'string') return { id: 'dev-' + dev, name: dev };
    if (typeof tok !== 'string' || tok.length < 20 || tok.length > 4000) return null;
    const r = await fetch(this.env.SUPABASE_URL + '/rest/v1/rpc/my_pilot', { method: 'POST', body: '{}',
      headers: { apikey: this.env.SUPABASE_KEY, Authorization: 'Bearer ' + tok, 'Content-Type': 'application/json' } });
    if (!r.ok) return null; const p = await r.json(); return p && p.id && !p.banned ? p : null;
  }

  async got(conn, raw) {
    if (typeof raw !== 'string' || raw.length > 700) return; const m = JSON.parse(raw); if (!m || typeof m !== 'object') return;
    const e = conn.ent;
    if (!e) {
      if (m.t !== 'hi' || conn.busy) return; conn.busy = true;
      let p = null; try { p = await this.pilot(m.tok, m.dev); } catch (err) {}
      if (!this.conns.has(conn)) return;
      if (!p) { this.send(conn, { t: 'no', why: 'auth' }); return this.drop(conn); }
      const old = this.ents.get(p.id);
      if (old) { const oc = old.conn; this.ents.delete(p.id); old.conn = null; if (oc) { oc.ent = null; this.drop(oc); } }
      if (this.humans() >= MAXH) { this.send(conn, { t: 'full' }); return this.drop(conn); }
      if (!this.c) this.c = Array.isArray(m.c) && m.c.length === 2 && m.c.every(num) ? [clamp(m.c[0], -6000, 6000), clamp(m.c[1], -6000, 6000)] : [0, -1900];
      const cnt = [0, 0]; for (const x of this.ents.values()) if (!x.bot) cnt[x.team]++;
      const team = cnt[0] < cnt[1] ? 0 : cnt[1] < cnt[0] ? 1 : this.sc[1] < this.sc[0] ? 1 : 0;
      const ent = this.make(p.id, String(p.name || 'Pilot').replace(/[<>&]/g, '').slice(0, 16), team, false);
      ent.k = Number.isInteger(m.k) ? clamp(m.k, 0, 31) : 0; ent.conn = conn; ent.fresh = false; conn.ent = ent;
      if (!this.start) { this.start = Date.now(); this.sc = [0, 0]; this.over = 0; }
      this.fill();
      this.send(conn, { t: 'in', id: ent.id, team, goal: GOAL, left: this.left(), sc: this.sc, c: this.c });
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
    } else if (m.t === 'x') { if (e.alive) this.kill(e, Date.now() - e.hitAt < 6000 ? this.ents.get(e.hitBy) : null); }
  }

  /* a client says its guns found someone: believe it only if the shot was possible */
  claim(e, m) {
    const t = this.ents.get(m.to); if (!t || !e.alive || !e.fresh || !t.alive || t.team === e.team || this.over || !num(m.d) || m.d <= 0) return;
    const d = Math.min(m.d, e.budget); if (d <= 0) return;
    const dx = t.p[0] - e.p[0], dy = t.p[1] - e.p[1], dz = t.p[2] - e.p[2], dist = Math.hypot(dx, dy, dz); if (dist > 750) return;
    const q = e.q, fx = -2 * (q[0] * q[2] + q[3] * q[1]), fy = -2 * (q[1] * q[2] - q[3] * q[0]), fz = -(1 - 2 * (q[0] * q[0] + q[1] * q[1]));
    if (dist > 40 && (fx * dx + fy * dy + fz * dz) / dist < .8) return;
    e.budget -= d; this.hurt(t, t.bot ? d : d * .5, e);
  }

  hurt(t, d, by) {
    t.hp -= d; t.hitAt = Date.now(); t.hitBy = by.id;
    if (t.bot) { if (Math.random() < .3) this.evade(t); } else if (t.conn) this.send(t.conn, { t: 'd', hp: Math.max(0, r1(t.hp)), by: by.id });
    if (t.hp <= 0) this.kill(t, by);
  }

  kill(v, by) {
    if (!v.alive || this.over) return; v.alive = false; v.hp = 0; v.f = 0; v.deaths++; v.fresh = false; v.resp = v.bot ? 4 : 3.2;
    this.sc[1 - v.team]++; if (by && by.team !== v.team) by.kills++;
    this.all({ t: 'k', i: v.id, by: by ? by.id : '', sc: this.sc });
  }

  left() { return this.start ? Math.max(0, Math.round(CAP - (Date.now() - this.start) / 1000)) : CAP; }

  make(id, name, team, bot) {
    const e = { id, name, team, bot, k: 0, conn: null, alive: true, hp: bot ? BOT_HP : 100, p: [0, 0, 0], q: [0, 0, 0, 1], vel: [0, 0, 0], f: 0, kills: 0, deaths: 0,
      resp: 0, hitAt: 0, hitBy: '', seen: Date.now(), pt: 0, budget: 200, fresh: true, yaw: 0, pitch: 0, roll: 0, v: 80, tgt: null, retT: 0, evT: 0, evYaw: 0, evPitch: 0 };
    this.place(e); this.ents.set(id, e); this.dirty = true; return e;
  }

  place(e) { // air start on the team's side of the field, nose toward the middle
    const side = e.team ? 1 : -1, c = this.c || [0, -1900];
    e.p[0] = c[0] + side * (1500 + rnd(0, 300)); e.p[1] = 480 + rnd(-60, 60); e.p[2] = c[1] + rnd(-250, 250);
    e.yaw = side > 0 ? PI / 2 : -PI / 2; e.pitch = 0; e.roll = 0; e.v = 80; e.evT = 0; e.tgt = null; e.retT = 0; e.vel = [0, 0, 0]; this.quat(e);
  }

  /* every side always flies SEATS aircraft: bots hold the seats no pilot has taken */
  fill() {
    this.dirty = true; if (!this.humans()) { for (const [id, e] of this.ents) if (e.bot) this.ents.delete(id); return; }
    for (let team = 0; team < 2; team++) {
      const mine = [...this.ents.values()].filter(e => e.team === team); let n = mine.length;
      for (const b of mine.filter(e => e.bot).sort((a, b) => a.alive - b.alive)) { if (n <= SEATS) break; this.ents.delete(b.id); n--; }
      for (; n < SEATS; n++) { const used = mine.map(e => e.name), name = BOT_NAMES[team].find(x => !used.includes(x)) || 'Bandit'; mine.push(this.make('b' + (++this.botN), name, team, true)); }
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
    if (b.evT > 0) { b.evT -= dt; wantYaw = b.evYaw; wantPitch = b.evPitch; }
    const hx = b.p[0] - c[0], hz = b.p[2] - c[1]; if (hx * hx + hz * hz > 3800 * 3800) { wantYaw = Math.atan2(hx, hz); b.evT = 0; }
    if (b.p[1] < 230) wantPitch = Math.max(wantPitch, .35); else if (b.p[1] > 1100) wantPitch = Math.min(wantPitch, -.2);
    const dyaw = clamp(wrap(wantYaw - b.yaw), -.82 * dt, .82 * dt); b.yaw = wrap(b.yaw + dyaw);
    b.pitch = clamp(b.pitch + clamp(clamp(wantPitch, -.55, .55) - b.pitch, -.6 * dt, .6 * dt), -.55, .55);
    b.roll += (clamp(dyaw / dt * 1.3, -1.1, 1.1) - b.roll) * Math.min(1, 4 * dt);
    b.v += (clamp(82 - b.pitch * 28, 62, 96) - b.v) * Math.min(1, dt);
    const nx = -Math.sin(b.yaw) * Math.cos(b.pitch), ny = Math.sin(b.pitch), nz = -Math.cos(b.yaw) * Math.cos(b.pitch);
    b.vel[0] = nx * b.v; b.vel[1] = ny * b.v; b.vel[2] = nz * b.v; b.p[0] += b.vel[0] * dt; b.p[1] = Math.max(60, b.p[1] + b.vel[1] * dt); b.p[2] += b.vel[2] * dt;
    this.quat(b); b.f = fire;
    if (fire && Math.random() < .5 * (1 - dist / 800)) this.hurt(t, t.bot ? 6 : 4, b);
  }

  tick() {
    const now = Date.now(), dt = clamp((now - this.last) / 1000, .001, .25); this.last = now;
    for (const c of this.conns) { if (c.ent ? now - c.ent.seen > 10000 : now - c.at > 12000) this.drop(c); }
    if (!this.humans()) return;
    if (this.over) { this.over -= dt; if (this.over <= 0) this.fresh(); }
    for (const e of this.ents.values()) {
      if (!e.alive) { e.resp -= dt; if (e.resp <= 0 && !this.over) { e.alive = true; e.hp = e.bot ? BOT_HP : 100; if (e.bot) this.place(e); else if (e.conn) this.send(e.conn, { t: 'r' }); } continue; }
      if (e.bot) this.bot(e, dt);
      else { e.budget = Math.min(260, e.budget + 170 * dt); if (now - e.hitAt > 6000 && e.hp < 100) e.hp = Math.min(100, e.hp + 7 * dt); }
    }
    if (this.dirty) { this.dirty = false; this.all({ t: 'ro', e: [...this.ents.values()].map(e => [e.id, e.name, e.team, e.k, e.bot ? 1 : 0]) }); }
    this.all({ t: 's', l: this.left(), sc: this.sc, e: [...this.ents.values()].map(e => [e.id, e.alive && e.fresh ? 1 : 0, r1(e.p[0]), r1(e.p[1]), r1(e.p[2]), r3(e.q[0]), r3(e.q[1]), r3(e.q[2]), r3(e.q[3]), e.f, e.kills, Math.round(e.hp)]) });
    if (!this.over && (this.sc[0] >= GOAL || this.sc[1] >= GOAL || this.left() <= 0)) { this.over = 9; for (const e of this.ents.values()) e.f = 0; this.all({ t: 'end', sc: this.sc }); }
  }

  fresh() { // the next match in the same room
    this.over = 0; this.sc = [0, 0]; this.start = Date.now();
    for (const e of this.ents.values()) { e.kills = 0; e.deaths = 0; e.alive = true; e.hp = e.bot ? BOT_HP : 100; e.hitAt = 0; if (e.bot) this.place(e); else { e.fresh = false; if (e.conn) this.send(e.conn, { t: 'r' }); } }
    this.all({ t: 'new', left: CAP, sc: this.sc });
  }
}
