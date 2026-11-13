-- Operation Windfall: the rules a public competition needs.
--   * every sortie is opened on the server, so a score can be checked against real elapsed time
--   * every change to a pilot's points is written to a ledger
--   * a pilot can be carried to another device with a recovery code, or deleted for good
--   * suspended pilots drop out of the ranking and can no longer score or buy
--   * the live channels are open to signed-in pilots only

alter table public.pilots add column if not exists banned boolean not null default false;

alter table public.scores drop constraint if exists scores_pilot_fkey;
alter table public.scores add constraint scores_pilot_fkey foreign key (pilot) references public.pilots (id) on delete cascade on update cascade;

create table if not exists public.sorties (
  id uuid primary key default gen_random_uuid(),
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  mission smallint not null check (mission between 0 and 6),
  diff smallint not null check (diff between 0 and 2),
  build integer,
  started_at timestamptz not null default now(),
  done_at timestamptz
);
create index if not exists sorties_pilot_started on public.sorties (pilot, started_at desc);

alter table public.scores add column if not exists sortie uuid unique references public.sorties (id) on delete set null;
create index if not exists scores_created on public.scores (created_at);

create table if not exists public.ledger (
  id bigint generated always as identity primary key,
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  kind text not null,                       -- seed, sortie, upgrade, plane, claim
  rp integer not null default 0,            -- change in requisition points
  tokens integer not null default 0,        -- change in purchased currency
  ref text,
  created_at timestamptz not null default now()
);
create index if not exists ledger_pilot_created on public.ledger (pilot, created_at desc);

-- Never readable from a device: only the functions below touch these.
create table if not exists public.pilot_secrets (
  pilot uuid primary key references public.pilots (id) on delete cascade on update cascade,
  recovery_hash text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.claim_tries (
  id bigint generated always as identity primary key,
  uid uuid not null,
  at timestamptz not null default now()
);
create index if not exists claim_tries_uid_at on public.claim_tries (uid, at);

alter table public.sorties enable row level security;
alter table public.ledger enable row level security;
alter table public.pilot_secrets enable row level security;
alter table public.claim_tries enable row level security;
drop policy if exists sorties_read_own on public.sorties;
create policy sorties_read_own on public.sorties for select to authenticated using (pilot = (select auth.uid()));
drop policy if exists ledger_read_own on public.ledger;
create policy ledger_read_own on public.ledger for select to authenticated using (pilot = (select auth.uid()));
revoke all on public.pilot_secrets, public.claim_tries from anon, authenticated;
revoke insert, update, delete, truncate on public.pilots, public.scores, public.sorties, public.ledger from anon, authenticated;

-- A pilot name: 3 to 16 letters, digits, spaces, dots, dashes or underscores; nothing reserved or abusive.
create or replace function public.clean_name(p_name text) returns text language plpgsql immutable set search_path = public as $$
declare nm text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')); lo text;
begin
  lo := lower(nm);
  if char_length(nm) < 3 or char_length(nm) > 16 or nm !~ '^[[:alnum:] _.-]+$' then raise exception 'bad_name'; end if;
  if lo ~ '(admin|moderator|support|official|windfall|supabase|fuck|shit|bitch|cunt|nigg|nazi|hitler|orospu|siktir|yarrak|hurensohn|fotze)' then raise exception 'bad_name'; end if;
  return nm;
end $$;

create or replace function public.join_pilot(p_name text, p_seed jsonb default null)
returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); nm text; r public.pilots; k text; u jsonb := '{}'; o smallint[] := '{}'; s smallint[] := '{0,0,0,0,0,0,0}'; i int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  nm := clean_name(p_name);
  select * into r from pilots where id = uid;
  begin
    if found then
      if r.banned then raise exception 'banned'; end if;
      update pilots set name = nm, updated_at = now() where id = uid returning * into r;
    else
      foreach k in array array['eng', 'arm', 'gun', 'ord'] loop u := u || jsonb_build_object(k, greatest(0, least(3, coalesce((p_seed -> 'up' ->> k)::int, 0)))); end loop;
      if jsonb_typeof(p_seed -> 'own') = 'array' then select coalesce(array_agg(distinct v::smallint), '{}') into o from jsonb_array_elements_text(p_seed -> 'own') v where v ~ '^[4-8]$'; end if;
      if jsonb_typeof(p_seed -> 'stars') = 'array' then for i in 0..6 loop s[i + 1] := (coalesce((p_seed -> 'stars' ->> i)::int, 0) & 7)::smallint; end loop; end if;
      insert into pilots (id, name, xp, rp, up, own, stars)
      values (uid, nm, greatest(0, least(40000, coalesce((p_seed ->> 'xp')::int, 0))), greatest(0, least(3000, coalesce((p_seed ->> 'rp')::int, 0))), u, o, s) returning * into r;
      insert into ledger (pilot, kind, rp, ref) values (uid, 'seed', r.rp, 'carried over from the device');
    end if;
  exception when unique_violation then raise exception 'name_taken';
  end;
  return r;
end $$;

-- Taking off. The server notes the moment; the score that comes back is checked against it.
create or replace function public.start_sortie(p_mission int, p_diff int, p_build int default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; sid uuid;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_mission is null or p_diff is null or p_mission not between 0 and 6 or p_diff not between 0 and 2 then raise exception 'bad_sortie'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if exists (select 1 from sorties where pilot = uid and started_at > now() - interval '3 seconds') then raise exception 'too_soon'; end if;
  delete from sorties where pilot = uid and done_at is null and started_at < now() - interval '1 day';
  insert into sorties (pilot, mission, diff, build) values (uid, p_mission, p_diff, p_build) returning id into sid;
  return sid;
end $$;

-- Landing, or not. One score per sortie, and only one the clock allows.
drop function if exists public.submit_score(int, int, int, int, boolean, int, jsonb);
create or replace function public.submit_score(p_sortie uuid, p_score int, p_time int, p_won boolean, p_stars int, p_stats jsonb default null)
returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; so public.sorties; sc int := coalesce(p_score, 0); tm int := greatest(0, coalesce(p_time, 0)); won boolean := coalesce(p_won, false); el numeric; earned int; st smallint[];
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  select * into so from sorties where id = p_sortie and pilot = uid for update;
  if not found then raise exception 'bad_sortie'; end if;
  if so.done_at is not null then raise exception 'already_scored'; end if;
  el := extract(epoch from now() - so.started_at);
  if el > 7200 then raise exception 'expired'; end if;
  if tm > el + 5 or (won and el < 45) then raise exception 'bad_sortie'; end if;
  if sc < 0 or sc > 20000 or sc > 2500 + 60 * el then raise exception 'bad_score'; end if;
  if p_stats is not null and pg_column_size(p_stats) > 2000 then p_stats := null; end if;
  earned := round(sc / (case when won then 10.0 else 25.0 end));
  st := r.stars; if won then st[so.mission + 1] := (st[so.mission + 1] | (coalesce(p_stars, 0) & 7))::smallint; end if;
  insert into scores (pilot, mission, diff, score, time_s, won, stats, sortie) values (uid, so.mission, so.diff, sc, tm, won, p_stats, so.id);
  insert into ledger (pilot, kind, rp, ref) values (uid, 'sortie', earned, so.id::text);
  update sorties set done_at = now() where id = so.id;
  update pilots set xp = xp + sc, rp = rp + earned, stars = st, sorties = sorties + 1, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.buy_upgrade(p_key text) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; lvl int; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_key is null or p_key not in ('eng', 'arm', 'gun', 'ord') then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  lvl := coalesce((r.up ->> p_key)::int, 0);
  if lvl >= 3 then raise exception 'maxed'; end if;
  cost := (array[300, 700, 1200])[lvl + 1];
  if r.rp < cost then raise exception 'not_enough'; end if;
  insert into ledger (pilot, kind, rp, ref) values (uid, 'upgrade', -cost, p_key || ':' || (lvl + 1));
  update pilots set rp = rp - cost, up = up || jsonb_build_object(p_key, lvl + 1), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.buy_plane(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between -1 and 8 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_i >= 4 and not (p_i = any (r.own)) then
    cost := (array[400, 600, 700, 900, 1100])[p_i - 3];
    if r.rp < cost then raise exception 'not_enough'; end if;
    insert into ledger (pilot, kind, rp, ref) values (uid, 'plane', -cost, p_i::text);
    update pilots set rp = rp - cost, own = own || p_i::smallint where id = uid;
  end if;
  update pilots set plane = p_i, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

-- The ranking: best score per sortie, added up. p_period 'week' counts only this calendar week (Monday, UTC).
drop function if exists public.leaderboard(int, int);
create or replace function public.leaderboard(p_mission int default null, p_limit int default 20, p_period text default 'all')
returns table (pos bigint, name text, score bigint, sorties integer, me boolean)
language sql security definer set search_path = public stable as $$
  with best as (
    select s.pilot, s.mission, max(s.score) as best from scores s
    where (p_mission is null or s.mission = p_mission) and (coalesce(p_period, 'all') <> 'week' or s.created_at >= date_trunc('week', now()))
    group by s.pilot, s.mission
  ), tot as (
    select b.pilot, sum(b.best)::bigint as score from best b group by b.pilot
  ), ranked as (
    select row_number() over (order by t.score desc, p.created_at) as pos, p.name, t.score, p.sorties, p.id = auth.uid() as me
    from tot t join pilots p on p.id = t.pilot where not p.banned
  )
  select * from ranked where pos <= greatest(1, least(100, coalesce(p_limit, 20))) or me order by pos;
$$;

-- A recovery code, shown once. Only its hash is kept. Making a new one cancels the old one.
create or replace function public.make_recovery() returns text language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); raw text;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if not exists (select 1 from pilots where id = uid) then raise exception 'no_pilot'; end if;
  raw := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8) || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
  insert into pilot_secrets (pilot, recovery_hash) values (uid, encode(sha256(convert_to(raw, 'UTF8')), 'hex'))
  on conflict (pilot) do update set recovery_hash = excluded.recovery_hash, created_at = now();
  return substr(raw, 1, 4) || '-' || substr(raw, 5, 4) || '-' || substr(raw, 9, 4) || '-' || substr(raw, 13, 4);
end $$;

-- Bring a pilot to this device with its name and recovery code. The code is used up; the old device loses the pilot.
create or replace function public.claim_pilot(p_name text, p_code text) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; mine public.pilots; raw text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); nm text := lower(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')));
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  delete from claim_tries where at < now() - interval '1 day';
  if (select count(*) from claim_tries where claim_tries.uid = claim_pilot.uid and at > now() - interval '1 hour') >= 5 then raise exception 'too_many'; end if;
  select p.* into r from pilots p join pilot_secrets s on s.pilot = p.id
  where lower(p.name) = nm and s.recovery_hash = encode(sha256(convert_to(raw, 'UTF8')), 'hex') for update of p;
  if not found or char_length(raw) <> 16 then
    insert into claim_tries (uid) values (uid);
    return null;                                  -- the device reads "no pilot" as a wrong name or code
  end if;
  if r.id = uid then return r; end if;
  select * into mine from pilots where id = uid for update;
  if found then
    if mine.sorties > 0 then raise exception 'has_pilot'; end if;
    delete from pilots where id = uid;
  end if;
  delete from pilot_secrets where pilot = r.id;
  update pilots set id = uid, updated_at = now() where id = r.id returning * into r;
  insert into ledger (pilot, kind, ref) values (uid, 'claim', 'moved to a new device');
  delete from claim_tries where claim_tries.uid = claim_pilot.uid;
  return r;
end $$;

-- Delete the pilot and everything recorded for it. Cannot be undone.
create or replace function public.delete_me() returns void language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  delete from pilots where id = uid;
  delete from auth.users where id = uid;
end $$;

revoke all on function public.clean_name(text), public.join_pilot(text, jsonb), public.start_sortie(int, int, int), public.submit_score(uuid, int, int, boolean, int, jsonb),
  public.buy_upgrade(text), public.buy_plane(int), public.make_recovery(), public.claim_pilot(text, text), public.delete_me(), public.leaderboard(int, int, text) from public, anon, authenticated;
grant execute on function public.join_pilot(text, jsonb), public.start_sortie(int, int, int), public.submit_score(uuid, int, int, boolean, int, jsonb),
  public.buy_upgrade(text), public.buy_plane(int), public.make_recovery(), public.claim_pilot(text, text), public.delete_me() to authenticated;
grant execute on function public.leaderboard(int, int, text) to anon, authenticated;

-- Live channels (shared sky, squadron lobby) are private: only signed-in pilots may listen or send.
drop policy if exists windfall_live_read on realtime.messages;
create policy windfall_live_read on realtime.messages for select to authenticated
  using ((realtime.topic() like 'sky:%' or realtime.topic() like 'sq:%') and exists (select 1 from public.pilots p where p.id = (select auth.uid()) and not p.banned));
drop policy if exists windfall_live_write on realtime.messages;
create policy windfall_live_write on realtime.messages for insert to authenticated
  with check ((realtime.topic() like 'sky:%' or realtime.topic() like 'sq:%') and exists (select 1 from public.pilots p where p.id = (select auth.uid()) and not p.banned));
