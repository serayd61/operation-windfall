-- Four more aircraft types (12 to 15, bought once like 4 to 8) and three weekly orders beside the daily ones.
-- Weekly progress, like daily progress, is never reported by the game: it is counted here from what the servers already recorded. Weeks start on Monday, UTC.

-- Choose an aircraft. -1 is the type each sortie issues, 0 to 3 are free, 4 to 8 and 12 to 15 are bought once, 9 to 11 open at 15, 30 and 45 stars.
create or replace function public.buy_plane(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between -1 and 15 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_i between 9 and 11 then
    if star_total(uid) < (array[15, 30, 45])[p_i - 8] then raise exception 'not_enough_stars'; end if;
  elsif p_i >= 4 and not (p_i = any (r.own)) then
    cost := case when p_i <= 8 then (array[400, 600, 700, 900, 1100])[p_i - 3] else (array[1000, 1200, 1300, 1400])[p_i - 11] end;
    if r.rp < cost then raise exception 'not_enough'; end if;
    insert into ledger (pilot, kind, rp, ref) values (uid, 'plane', -cost, p_i::text);
    update pilots set rp = rp - cost, own = own || p_i::smallint where id = uid;
  end if;
  update pilots set plane = p_i, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create table if not exists public.weekly_claims (
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  week date not null,                                     -- the Monday the week began on
  slot smallint not null check (slot between 1 and 3),
  rp integer not null,
  created_at timestamptz not null default now(),
  primary key (pilot, week, slot)
);
alter table public.weekly_claims enable row level security;

-- the same three orders for everyone in a given week: one from the sorties, one from the team dogfight, and turning up on five days
create or replace function public.weekly_tasks(p_week date) returns table (slot int, key text, goal int, rp int)
language sql immutable set search_path = public as $$
  with w as (select (greatest(0, p_week - date '2026-01-05') / 7) % 3 + 1 as i)
  select 1, (array['sorties', 'win', 'score'])[w.i], (array[10, 6, 20000])[w.i], (array[250, 300, 300])[w.i] from w
  union all select 2, (array['dkills', 'dwin', 'duel'])[w.i], (array[40, 5, 10])[w.i], (array[350, 300, 250])[w.i] from w
  union all select 3, 'days', 5, 300 from w;
$$;

create or replace function public.weekly_have(p_pilot uuid, p_key text, p_week date) returns integer
language sql stable security definer set search_path = public as $$
  with t as (select p_week::timestamp at time zone 'utc' as a, (p_week + 7)::timestamp at time zone 'utc' as b)
  select coalesce(case p_key
    when 'sorties' then (select count(*) from scores, t where pilot = p_pilot and created_at >= t.a and created_at < t.b)
    when 'win' then (select count(*) from scores, t where pilot = p_pilot and won and created_at >= t.a and created_at < t.b)
    when 'score' then (select sum(score) from scores, t where pilot = p_pilot and created_at >= t.a and created_at < t.b)
    when 'duel' then (select count(*) from duel_results, t where pilot = p_pilot and created_at >= t.a and created_at < t.b)
    when 'dkills' then (select sum(kills) from duel_results, t where pilot = p_pilot and created_at >= t.a and created_at < t.b)
    when 'dwin' then (select count(*) from duel_results, t where pilot = p_pilot and won and created_at >= t.a and created_at < t.b)
    when 'days' then (select count(*) from daily_claims where pilot = p_pilot and slot = 0 and day >= p_week and day < p_week + 7)
  end, 0)::integer;
$$;

create or replace function public.weekly_list(p_pilot uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  with w as (select date_trunc('week', now() at time zone 'utc')::date as d)
  select coalesce(jsonb_agg(jsonb_build_object('slot', t.slot, 'key', t.key, 'goal', t.goal, 'rp', t.rp,
      'have', least(t.goal, weekly_have(p_pilot, t.key, w.d)),
      'claimed', exists (select 1 from weekly_claims c where c.pilot = p_pilot and c.week = w.d and c.slot = t.slot)) order by t.slot), '[]'::jsonb)
  from w, weekly_tasks(w.d) t;
$$;

-- the daily state now carries the week's orders as well
create or replace function public.daily_state() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; d date := (now() at time zone 'utc')::date; t0 timestamptz; got boolean; s int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid;
  if not found then raise exception 'no_pilot'; end if;
  t0 := d::timestamp at time zone 'utc';
  got := exists (select 1 from daily_claims where pilot = uid and day = d and slot = 0);
  s := case when got then r.streak when r.streak_day = d - 1 then r.streak + 1 else 1 end;
  return jsonb_build_object('day', d, 'streak', s, 'rp', r.rp,
    'login', jsonb_build_object('claimed', got, 'rp', daily_pay(s)),
    'tasks', (select jsonb_agg(jsonb_build_object('slot', t.slot, 'key', t.key, 'goal', t.goal, 'rp', t.rp,
        'have', least(t.goal, daily_have(uid, t.key, t0)),
        'claimed', exists (select 1 from daily_claims c where c.pilot = uid and c.day = d and c.slot = t.slot)) order by t.slot)
      from daily_tasks(d) t),
    'week', weekly_list(uid));
end $$;

create or replace function public.weekly_claim(p_slot int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; w date := date_trunc('week', now() at time zone 'utc')::date; t record;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  select * into t from weekly_tasks(w) x where x.slot = p_slot;
  if not found then raise exception 'bad_slot'; end if;
  if exists (select 1 from weekly_claims where pilot = uid and week = w and slot = p_slot) then raise exception 'already'; end if;
  if weekly_have(uid, t.key, w) < t.goal then raise exception 'not_done'; end if;
  update pilots set rp = rp + t.rp, updated_at = now() where id = uid;
  insert into weekly_claims (pilot, week, slot, rp) values (uid, w, p_slot, t.rp);
  insert into ledger (pilot, kind, rp, ref) values (uid, 'weekly', t.rp, w::text || ':' || p_slot);
  return daily_state();
end $$;

revoke all on function public.weekly_tasks(date), public.weekly_have(uuid, text, date), public.weekly_list(uuid), public.weekly_claim(int) from public, anon, authenticated;
grant execute on function public.weekly_claim(int) to authenticated;
revoke all on public.weekly_claims from anon, authenticated;
