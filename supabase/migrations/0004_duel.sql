-- Team dogfight results. Only the match server may write them: it proves itself with a key
-- whose SHA-256 is kept here (the key itself lives only in the server's secrets).
create table if not exists public.duel_results (
  id bigint generated always as identity primary key,
  pilot uuid not null references public.pilots (id) on delete cascade,
  kills smallint not null check (kills between 0 and 60),
  deaths smallint not null check (deaths between 0 and 200),
  won boolean not null,
  points integer not null,
  created_at timestamptz not null default now()
);
create index if not exists duel_results_pilot on public.duel_results (pilot, created_at);
alter table public.duel_results enable row level security;

create table if not exists public.server_keys (name text primary key, hash text not null);
alter table public.server_keys enable row level security;
insert into public.server_keys (name, hash) values ('duel', 'a06bd781601e48b538068a6332df4d081b7ec3c9e6621221fbd2d7e1f7561956')
  on conflict (name) do update set hash = excluded.hash;

create or replace function public.duel_report(p_key text, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb; n integer := 0; k integer; d integer; w boolean; pid uuid;
begin
  if not exists (select 1 from server_keys where name = 'duel' and hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')) then
    raise exception 'forbidden';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 8 then raise exception 'bad_rows'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    pid := (r->>'id')::uuid; k := least(60, greatest(0, coalesce((r->>'k')::int, 0))); d := least(200, greatest(0, coalesce((r->>'d')::int, 0))); w := coalesce((r->>'w')::int, 0) = 1;
    if exists (select 1 from pilots where id = pid and not banned) then
      insert into duel_results (pilot, kills, deaths, won, points) values (pid, k, d, w, k * 10 + case when w then 30 else 0 end);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.duel_board(p_limit int default 20, p_period text default 'all')
returns table (pos bigint, name text, score bigint, matches bigint, wins bigint, me boolean)
language sql security definer set search_path = public stable as $$
  with tot as (
    select d.pilot, sum(d.points)::bigint as score, count(*)::bigint as matches, count(*) filter (where d.won)::bigint as wins
    from duel_results d where coalesce(p_period, 'all') <> 'week' or d.created_at >= date_trunc('week', now()) group by d.pilot
  ), ranked as (
    select row_number() over (order by t.score desc, p.created_at) as pos, p.name, t.score, t.matches, t.wins, p.id = auth.uid() as me
    from tot t join pilots p on p.id = t.pilot where not p.banned
  )
  select * from ranked where pos <= greatest(1, least(100, coalesce(p_limit, 20))) or me order by pos;
$$;

revoke all on function public.duel_report(text, jsonb), public.duel_board(int, text) from public;
grant execute on function public.duel_report(text, jsonb) to anon, authenticated;
grant execute on function public.duel_board(int, text) to anon, authenticated;
