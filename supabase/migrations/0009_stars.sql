-- Stars open things: the last three aircraft types and every paint. A pilot's stars are those of the sorties
-- (pilots.stars) and of the campaign (chapter_stars) together; they are counted here and never spent.
alter table public.pilots add column if not exists paint smallint not null default 0;

create or replace function public.star_total(p_pilot uuid) returns integer
language sql stable security definer set search_path = public as $$
  select (coalesce((select sum(chapter_n(c.stars)) from chapter_stars c where c.pilot = p_pilot), 0)
        + coalesce((select sum(chapter_n(s)) from pilots p, unnest(p.stars) s where p.id = p_pilot), 0))::integer;
$$;

-- Choose an aircraft. -1 is the type each sortie issues, 0 to 3 are free, 4 to 8 are bought once, 9 to 11 open at 15, 30 and 45 stars.
create or replace function public.buy_plane(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots; cost int;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between -1 and 11 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if p_i >= 9 then
    if star_total(uid) < (array[15, 30, 45])[p_i - 8] then raise exception 'not_enough_stars'; end if;
  elsif p_i >= 4 and not (p_i = any (r.own)) then
    cost := (array[400, 600, 700, 900, 1100])[p_i - 3];
    if r.rp < cost then raise exception 'not_enough'; end if;
    insert into ledger (pilot, kind, rp, ref) values (uid, 'plane', -cost, p_i::text);
    update pilots set rp = rp - cost, own = own || p_i::smallint where id = uid;
  end if;
  update pilots set plane = p_i, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

-- Choose a paint: 0 is the factory finish, 1 to 6 open at 6, 12, 20, 30, 42 and 55 stars.
create or replace function public.set_paint(p_i int) returns public.pilots language plpgsql security definer set search_path = public as $$
declare uid uuid := auth.uid(); r public.pilots;
begin
  if uid is null then raise exception 'not_signed_in'; end if;
  if p_i is null or p_i not between 0 and 6 then raise exception 'bad_item'; end if;
  select * into r from pilots where id = uid for update;
  if not found then raise exception 'no_pilot'; end if;
  if r.banned then raise exception 'banned'; end if;
  if star_total(uid) < (array[0, 6, 12, 20, 30, 42, 55])[p_i + 1] then raise exception 'not_enough_stars'; end if;
  update pilots set paint = p_i, updated_at = now() where id = uid returning * into r;
  return r;
end $$;

revoke all on function public.star_total(uuid), public.set_paint(int) from public, anon, authenticated;
grant execute on function public.set_paint(int) to authenticated;
