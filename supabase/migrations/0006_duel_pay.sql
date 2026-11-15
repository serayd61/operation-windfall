-- A team dogfight now pays like a sortie: requisition points and experience, written by the
-- match server's report. 20 for flying, 8 a kill, 40 for the win; experience equals the ranking points.
create or replace function public.duel_report(p_key text, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb; n integer := 0; k integer; d integer; w boolean; pid uuid; pts integer; pay integer;
begin
  if not exists (select 1 from server_keys where name = 'duel' and hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')) then
    raise exception 'forbidden';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 8 then raise exception 'bad_rows'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    pid := (r->>'id')::uuid; k := least(60, greatest(0, coalesce((r->>'k')::int, 0))); d := least(200, greatest(0, coalesce((r->>'d')::int, 0))); w := coalesce((r->>'w')::int, 0) = 1;
    if exists (select 1 from pilots where id = pid and not banned) then
      pts := k * 10 + case when w then 30 else 0 end; pay := 20 + k * 8 + case when w then 40 else 0 end;
      insert into duel_results (pilot, kills, deaths, won, points) values (pid, k, d, w, pts);
      insert into ledger (pilot, kind, rp, ref) values (pid, 'duel', pay, k || ':' || d || ':' || w::int);
      update pilots set rp = rp + pay, xp = xp + pts, updated_at = now() where id = pid;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
