-- The pilot himself: skills in four branches of four steps, fittings bought once, and the two chosen for the flight.
-- Sixteen levels are read off the experience already earned; each gives one skill point. Nothing here is spent on stars or tokens.

alter table public.pilots add column if not exists sk jsonb not null default '{"fly":0,"gun":0,"tough":0,"tac":0}';
alter table public.pilots add column if not exists parts smallint[] not null default '{}';
alter table public.pilots add column if not exists kit jsonb not null default '{"g":0,"k":0}';
-- what the pilot wears: piece 1, the flying helmet, is issued; 2 to 11 are bought. One on the head (1-4), one on the body (5-7), one carried (8-11).
alter table public.pilots add column if not exists gear smallint[] not null default '{}';
alter table public.pilots add column if not exists wear jsonb not null default '{"h":1,"b":0,"k":0}';

create or replace function public.pilot_level(p_xp int) returns int language sql immutable as $$
  select count(*)::int from unnest(array[0, 600, 1500, 2700, 4200, 6000, 8200, 10800, 13800, 17200, 21000, 25500, 30500, 36000, 42000, 48000]) t(x) where coalesce(p_xp, 0) >= x;
$$;

create or replace function public.skill_up(p_key text) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; have int; spent int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_key is null or p_key not in ('fly', 'gun', 'tough', 'tac') then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  have := coalesce((r.sk ->> p_key)::int, 0);
  if have >= 4 then raise exception 'maxed'; end if;
  spent := coalesce((r.sk ->> 'fly')::int, 0) + coalesce((r.sk ->> 'gun')::int, 0) + coalesce((r.sk ->> 'tough')::int, 0) + coalesce((r.sk ->> 'tac')::int, 0);
  if spent >= pilot_level(r.xp) then raise exception 'not_enough'; end if;
  update pilots set sk = sk || jsonb_build_object(p_key, have + 1), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.skill_reset() returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  update pilots set sk = '{"fly":0,"gun":0,"tough":0,"tac":0}', updated_at = now() where id = uid and not banned returning * into r;
  if not found then raise exception 'no_pilot'; end if;
  return r;
end $$;

-- Fittings 1 to 3 are bought and ask for a pilot level; 4 and 5 open with stars and are never bought.
create or replace function public.buy_part(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int; need int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between 1 and 3 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_i = any (r.parts) then raise exception 'maxed'; end if;
  cost := (array[300, 500, 600])[p_i]; need := (array[1, 4, 3])[p_i];
  if pilot_level(r.xp) < need then raise exception 'bad_item'; end if;
  if r.rp < cost then raise exception 'not_enough'; end if;
  insert into ledger (pilot, kind, rp, ref) values (uid, 'part', -cost, p_i::text);
  update pilots set rp = rp - cost, parts = array_append(parts, p_i::smallint), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.set_kit(p_g int, p_k int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; g int := coalesce(p_g, 0); k int := coalesce(p_k, 0);
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if g not in (0, 1, 2) or k not in (0, 3, 4, 5) then raise exception 'bad_item'; end if;
  if g > 0 and not (g = any (r.parts)) then raise exception 'bad_item'; end if;
  if k = 3 and not (3 = any (r.parts)) then raise exception 'bad_item'; end if;
  if k = 4 and star_total(uid) < 25 then raise exception 'not_enough_stars'; end if;
  if k = 5 and star_total(uid) < 40 then raise exception 'not_enough_stars'; end if;
  update pilots set kit = jsonb_build_object('g', g, 'k', k), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

-- Buying a piece puts it on.
create or replace function public.buy_gear(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int; sl text;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between 2 and 11 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_i = any (r.gear) then raise exception 'maxed'; end if;
  cost := (array[0, 250, 300, 350, 300, 350, 450, 200, 200, 300, 400])[p_i];
  if r.rp < cost then raise exception 'not_enough'; end if;
  sl := case when p_i <= 4 then 'h' when p_i <= 7 then 'b' else 'k' end;
  insert into ledger (pilot, kind, rp, ref) values (uid, 'gear', -cost, p_i::text);
  update pilots set rp = rp - cost, gear = array_append(gear, p_i::smallint), wear = wear || jsonb_build_object(sl, p_i), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

create or replace function public.set_wear(p_h int, p_b int, p_k int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; h int := coalesce(p_h, 0); b int := coalesce(p_b, 0); k int := coalesce(p_k, 0);
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if h not between 0 and 4 or (b <> 0 and b not between 5 and 7) or (k <> 0 and k not between 8 and 11) then raise exception 'bad_item'; end if;
  if (h > 1 and not (h = any (r.gear))) or (b > 0 and not (b = any (r.gear))) or (k > 0 and not (k = any (r.gear))) then raise exception 'bad_item'; end if;
  update pilots set wear = jsonb_build_object('h', h, 'b', b, 'k', k), updated_at = now() where id = uid returning * into r;
  return r;
end $$;

revoke all on function public.buy_gear(int), public.set_wear(int, int, int) from public, anon;
grant execute on function public.buy_gear(int), public.set_wear(int, int, int) to authenticated;

revoke all on function public.skill_up(text), public.skill_reset(), public.buy_part(int), public.set_kit(int, int) from public, anon;
grant execute on function public.skill_up(text), public.skill_reset(), public.buy_part(int), public.set_kit(int, int) to authenticated;

-- A flown sortie, as before, with the third step of Tactics paying 8% more requisition, a life vest 4% more on a sortie won and a parachute half as much again on one lost.
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
  earned := round(round(sc / (case when won then 10.0 else 25.0 end)) * (case when coalesce((r.sk ->> 'tac')::int, 0) >= 3 then 1.08 else 1 end)
    * (case when won and (r.wear ->> 'b') = '6' then 1.04 when not won and (r.wear ->> 'b') = '7' then 1.5 else 1 end));
  st := r.stars; if won then st[so.mission + 1] := (st[so.mission + 1] | (coalesce(p_stars, 0) & 7))::smallint; end if;
  insert into scores (pilot, mission, diff, score, time_s, won, stats, sortie) values (uid, so.mission, so.diff, sc, tm, won, p_stats, so.id);
  insert into ledger (pilot, kind, rp, ref) values (uid, 'sortie', earned, so.id::text);
  update sorties set done_at = now() where id = so.id;
  update pilots set xp = xp + sc, rp = rp + earned, stars = st, sorties = sorties + 1, updated_at = now() where id = uid returning * into r;
  return r;
end $$;
