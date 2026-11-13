-- Operation Windfall: pilots, scores and the equipment economy.
-- Players never write to these tables directly. Every change goes through a function below,
-- which checks who is calling and applies the game's rules on the server.

create table if not exists public.pilots (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (char_length(name) between 3 and 16),
  xp integer not null default 0 check (xp >= 0),
  rp integer not null default 0 check (rp >= 0),          -- requisition points, earned by flying
  tokens integer not null default 0 check (tokens >= 0),  -- reserved for purchased currency
  up jsonb not null default '{"eng":0,"arm":0,"gun":0,"ord":0}',
  own smallint[] not null default '{}',
  plane smallint not null default -1,
  stars smallint[] not null default '{0,0,0,0,0,0,0}',
  sorties integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists pilots_name_key on public.pilots (lower(name));

create table if not exists public.scores (
  id bigint generated always as identity primary key,
  pilot uuid not null references public.pilots (id) on delete cascade,
  mission smallint not null check (mission between 0 and 6),
  diff smallint not null check (diff between 0 and 2),
  score integer not null check (score between 0 and 20000),
  time_s integer not null check (time_s >= 0),
  won boolean not null,
  stats jsonb,
  created_at timestamptz not null default now()
);
create index if not exists scores_mission_score on public.scores (mission, score desc);
create index if not exists scores_pilot_mission on public.scores (pilot, mission);

alter table public.pilots enable row level security;
alter table public.scores enable row level security;
drop policy if exists pilots_read_own on public.pilots;
create policy pilots_read_own on public.pilots for select to authenticated using (id = (select auth.uid()));
drop policy if exists scores_read_own on public.scores;
create policy scores_read_own on public.scores for select to authenticated using (pilot = (select auth.uid()));

-- Sign up or rename. On first sign-up the progress already made on the device is carried over, within limits.
create or replace function public.join_pilot(p_name text, p_seed jsonb default null)
returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')); r public.pilots; k text; u jsonb := '{}'; o smallint[] := '{}'; s smallint[] := '{0,0,0,0,0,0,0}'; i int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if char_length(nm) < 3 or char_length(nm) > 16 or nm ~ '[<>&"''\\/]' then raise exception 'bad_name'; end if;
  select * into r from pilots where id = uid;
  begin
    if found then
      update pilots set name = nm, updated_at = now() where id = uid returning * into r;
    else
      foreach k in array array['eng', 'arm', 'gun', 'ord'] loop u := u || jsonb_build_object(k, greatest(0, least(3, coalesce((p_seed -> 'up' ->> k)::int, 0)))); end loop;
      if jsonb_typeof(p_seed -> 'own') = 'array' then select coalesce(array_agg(distinct v::smallint), '{}') into o from jsonb_array_elements_text(p_seed -> 'own') v where v ~ '^[4-8]$'; end if;
      if jsonb_typeof(p_seed -> 'stars') = 'array' then for i in 0..6 loop s[i + 1] := (coalesce((p_seed -> 'stars' ->> i)::int, 0) & 7)::smallint; end loop; end if;
      insert into pilots (id, name, xp, rp, up, own, stars)
      values (uid, nm, greatest(0, least(40000, coalesce((p_seed ->> 'xp')::int, 0))), greatest(0, least(3000, coalesce((p_seed ->> 'rp')::int, 0))), u, o, s) returning * into r;
    end if;
  exception when unique_violation then raise exception 'name_taken';
  end;
  return r;
end $$;

create or replace function public.my_pilot() returns public.pilots language sql security definer set search_path = public stable as $$
  select * from pilots where id = auth.uid();
$$;

-- A flown sortie. The reward is worked out here, not on the device.
create or replace function public.submit_score(p_mission int, p_diff int, p_score int, p_time int, p_won boolean, p_stars int, p_stats jsonb default null)
returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; sc int := greatest(0, least(20000, coalesce(p_score, 0))); earned int; st smallint[];
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_mission not between 0 and 6 or p_diff not between 0 and 2 then raise exception 'bad_sortie'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if exists (select 1 from scores where pilot = uid and created_at > now() - interval '20 seconds') then raise exception 'too_soon'; end if;
  if p_won and coalesce(p_time, 0) < 45 then raise exception 'bad_sortie'; end if;
  earned := round(sc / (case when p_won then 10.0 else 25.0 end));
  st := r.stars; if p_won then st[p_mission + 1] := (st[p_mission + 1] | (coalesce(p_stars, 0) & 7))::smallint; end if;
  insert into scores (pilot, mission, diff, score, time_s, won, stats) values (uid, p_mission, p_diff, sc, greatest(0, coalesce(p_time, 0)), p_won, p_stats);
  update pilots set xp = xp + sc, rp = rp + earned, stars = st, sorties = sorties + 1, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.buy_upgrade(p_key text) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; lvl int; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_key not in ('eng', 'arm', 'gun', 'ord') then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  lvl := coalesce((r.up ->> p_key)::int, 0);
  if lvl >= 3 then raise exception 'maxed'; end if;
  cost := (array[300, 700, 1200])[lvl + 1];
  if r.rp < cost then raise exception 'not_enough'; end if;
  update pilots set rp = rp - cost, up = up || jsonb_build_object(p_key, lvl + 1), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

-- Choose an aircraft, buying it first if it is not owned yet. -1 is the type each sortie issues, 0 to 3 are free.
create or replace function public.buy_plane(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i not between -1 and 8 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if p_i >= 4 and not (p_i = any (r.own)) then
    cost := (array[400, 600, 700, 900, 1100])[p_i - 3];
    if r.rp < cost then raise exception 'not_enough'; end if;
    update pilots set rp = rp - cost, own = own || p_i::smallint where id = uid;
  end if;
  update pilots set plane = p_i, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

-- The ranking: a pilot's best score on each sortie, added up, or the best on one sortie.
-- Returns the top of the table plus the caller's own row.
create or replace function public.leaderboard(p_mission int default null, p_limit int default 20)
returns table (pos bigint, name text, score bigint, sorties integer, me boolean)
language sql security definer set search_path = public stable as $$
  with best as (
    select pilot, mission, max(score) as best from scores where p_mission is null or mission = p_mission group by pilot, mission
  ), tot as (
    select b.pilot, sum(b.best)::bigint as score from best b group by b.pilot
  ), ranked as (
    select row_number() over (order by t.score desc, p.created_at) as pos, p.name, t.score, p.sorties, p.id = auth.uid() as me
    from tot t join pilots p on p.id = t.pilot
  )
  select * from ranked where pos <= greatest(1, least(100, coalesce(p_limit, 20))) or me order by pos;
$$;

revoke all on function public.join_pilot(text, jsonb), public.my_pilot(), public.submit_score(int, int, int, int, boolean, int, jsonb), public.buy_upgrade(text), public.buy_plane(int) from public, anon;
grant execute on function public.join_pilot(text, jsonb), public.my_pilot(), public.submit_score(int, int, int, int, boolean, int, jsonb), public.buy_upgrade(text), public.buy_plane(int) to authenticated;
grant execute on function public.leaderboard(int, int) to anon, authenticated;
