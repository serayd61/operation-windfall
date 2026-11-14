-- Daily pay (a login streak) and three daily orders. Progress is never reported by the game:
-- it is counted here from the sorties and team dogfights the servers already recorded. Days are UTC.
alter table public.pilots add column if not exists streak integer not null default 0;
alter table public.pilots add column if not exists streak_day date;

create table if not exists public.daily_claims (
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  day date not null,
  slot smallint not null check (slot between 0 and 3),   -- 0 = daily pay, 1-3 = the day's orders
  rp integer not null,
  created_at timestamptz not null default now(),
  primary key (pilot, day, slot)
);
alter table public.daily_claims enable row level security;

-- the same three orders for everyone on a given day: one from the sorties, one from the team dogfight, one more from either
create or replace function public.daily_tasks(p_day date) returns table (slot int, key text, goal int, rp int)
language sql immutable set search_path = public as $$
  with pool (grp, i, key, goal, rp) as (values
    (0, 0, 'sorties', 2, 60), (0, 1, 'win', 1, 80), (0, 2, 'score', 3000, 80),
    (1, 0, 'duel', 2, 60), (1, 1, 'dkills', 8, 100), (1, 2, 'dwin', 1, 80)
  ), d as (select greatest(0, p_day - date '2026-01-01') as n)
  select 1, p.key, p.goal, p.rp from pool p, d where p.grp = 0 and p.i = d.n % 3
  union all select 2, p.key, p.goal, p.rp from pool p, d where p.grp = 1 and p.i = (d.n / 3) % 3
  union all select 3, p.key, p.goal, p.rp from pool p, d where p.grp = d.n % 2 and p.i = case when d.n % 2 = 0 then (d.n + 1) % 3 else (d.n / 3 + 1) % 3 end;
$$;

create or replace function public.daily_have(p_pilot uuid, p_key text, p_from timestamptz) returns integer
language sql stable security definer set search_path = public as $$
  select coalesce(case p_key
    when 'sorties' then (select count(*) from scores where pilot = p_pilot and created_at >= p_from and created_at < p_from + interval '1 day')
    when 'win' then (select count(*) from scores where pilot = p_pilot and won and created_at >= p_from and created_at < p_from + interval '1 day')
    when 'score' then (select sum(score) from scores where pilot = p_pilot and created_at >= p_from and created_at < p_from + interval '1 day')
    when 'duel' then (select count(*) from duel_results where pilot = p_pilot and created_at >= p_from and created_at < p_from + interval '1 day')
    when 'dkills' then (select sum(kills) from duel_results where pilot = p_pilot and created_at >= p_from and created_at < p_from + interval '1 day')
    when 'dwin' then (select count(*) from duel_results where pilot = p_pilot and won and created_at >= p_from and created_at < p_from + interval '1 day')
  end, 0)::integer;
$$;

create or replace function public.daily_pay(p_streak int) returns integer language sql immutable as $$
  select (array[40, 60, 80, 100, 120, 150, 250])[((greatest(1, p_streak) - 1) % 7) + 1];
$$;

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
      from daily_tasks(d) t));
end $$;

create or replace function public.daily_claim(p_slot int) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; d date := (now() at time zone 'utc')::date; t0 timestamptz; t record; s int; pay int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_slot is null or p_slot < 0 or p_slot > 3 then raise exception 'bad_slot'; end if;
  if exists (select 1 from daily_claims where pilot = uid and day = d and slot = p_slot) then raise exception 'already'; end if;
  t0 := d::timestamp at time zone 'utc';
  if p_slot = 0 then
    s := case when r.streak_day = d - 1 then r.streak + 1 else 1 end; pay := daily_pay(s);
    update pilots set streak = s, streak_day = d, rp = rp + pay, updated_at = now() where id = uid;
  else
    select * into t from daily_tasks(d) x where x.slot = p_slot;
    if not found then raise exception 'bad_slot'; end if;
    if daily_have(uid, t.key, t0) < t.goal then raise exception 'not_done'; end if;
    pay := t.rp;
    update pilots set rp = rp + pay, updated_at = now() where id = uid;
  end if;
  insert into daily_claims (pilot, day, slot, rp) values (uid, d, p_slot, pay);
  insert into ledger (pilot, kind, rp, ref) values (uid, 'daily', pay, d::text || ':' || p_slot);
  return daily_state();
end $$;

revoke all on function public.daily_tasks(date), public.daily_have(uuid, text, timestamptz), public.daily_pay(int), public.daily_state(), public.daily_claim(int) from public, anon, authenticated;
grant execute on function public.daily_state(), public.daily_claim(int) to authenticated;
