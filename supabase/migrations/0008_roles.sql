-- Role experience: a pilot flies online as a fighter (f), an attacker (a) or a bomber (b), and each role keeps its own experience.
-- Only the match server may write it, with the same key it reports team dogfights with. The level is read from the experience:
-- level n starts at 100 * (n - 1)^2, up to level 10 at 8100.
create table if not exists public.role_xp (
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  role text not null check (role in ('f', 'a', 'b')),
  xp integer not null default 0 check (xp >= 0),
  matches integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (pilot, role)
);
alter table public.role_xp enable row level security;
revoke all on public.role_xp from anon, authenticated;

create or replace function public.role_report(p_key text, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb; n integer := 0; pid uuid; rl text; x integer;
begin
  if not exists (select 1 from server_keys where name = 'duel' and hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')) then
    raise exception 'forbidden';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 8 then raise exception 'bad_rows'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    pid := (r->>'id')::uuid; rl := r->>'r'; x := least(400, greatest(0, coalesce((r->>'x')::int, 0)));
    if rl not in ('f', 'a', 'b') or x = 0 then continue; end if;
    if not exists (select 1 from pilots where id = pid and not banned) then continue; end if;
    insert into role_xp (pilot, role, xp, matches) values (pid, rl, x, 1)
      on conflict (pilot, role) do update set xp = role_xp.xp + excluded.xp, matches = role_xp.matches + 1, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;

-- a pilot's own roles: the experience in each
create or replace function public.my_roles() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'f', coalesce((select xp from role_xp where pilot = auth.uid() and role = 'f'), 0),
    'a', coalesce((select xp from role_xp where pilot = auth.uid() and role = 'a'), 0),
    'b', coalesce((select xp from role_xp where pilot = auth.uid() and role = 'b'), 0));
$$;

revoke all on function public.role_report(text, jsonb), public.my_roles() from public, anon, authenticated;
grant execute on function public.role_report(text, jsonb) to anon, authenticated;
grant execute on function public.my_roles() to authenticated;
