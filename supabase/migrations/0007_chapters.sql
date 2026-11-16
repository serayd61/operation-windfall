-- The campaign: twenty chapters on four fronts, flown on the match server against bots.
-- A chapter keeps three stars a pilot (bit 1 the side won, bit 2 one of its two best, bit 4 shot down three times at most);
-- only the match server may write them, with the same key it reports team dogfights with.
-- A front opens once the one before it holds ten stars. A star pays once: 30 requisition points and 50 experience.
create table if not exists public.chapter_stars (
  pilot uuid not null references public.pilots (id) on delete cascade on update cascade,
  chapter smallint not null check (chapter between 1 and 20),
  stars smallint not null default 0 check (stars between 0 and 7),
  plays integer not null default 1,
  updated_at timestamptz not null default now(),
  primary key (pilot, chapter)
);
alter table public.chapter_stars enable row level security;
revoke all on public.chapter_stars from anon, authenticated;

create or replace function public.chapter_n(p_bits int) returns integer language sql immutable as $$
  select (p_bits & 1) + ((p_bits >> 1) & 1) + ((p_bits >> 2) & 1);
$$;

create or replace function public.chapter_report(p_key text, p_ch int, p_rows jsonb) returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb; n integer := 0; pid uuid; s integer; old integer; gain integer; front integer;
begin
  if not exists (select 1 from server_keys where name = 'duel' and hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex')) then
    raise exception 'forbidden';
  end if;
  if p_ch is null or p_ch < 1 or p_ch > 20 then raise exception 'bad_chapter'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 4 then raise exception 'bad_rows'; end if;
  front := (p_ch - 1) / 5;
  for r in select * from jsonb_array_elements(p_rows) loop
    pid := (r->>'id')::uuid; s := coalesce((r->>'s')::int, 0) & 7;
    if s & 1 = 0 then continue; end if;                                   -- a lost chapter pays nothing
    if not exists (select 1 from pilots where id = pid and not banned) then continue; end if;
    if front > 0 and (select coalesce(sum(chapter_n(c.stars)), 0) from chapter_stars c where c.pilot = pid and c.chapter between (front - 1) * 5 + 1 and front * 5) < 10 then continue; end if;   -- that front is not open to him yet
    select c.stars into old from chapter_stars c where c.pilot = pid and c.chapter = p_ch for update;
    old := coalesce(old, 0); gain := chapter_n(old | s) - chapter_n(old);
    insert into chapter_stars (pilot, chapter, stars) values (pid, p_ch, s)
      on conflict (pilot, chapter) do update set stars = chapter_stars.stars | excluded.stars, plays = chapter_stars.plays + 1, updated_at = now();
    if gain > 0 then
      insert into ledger (pilot, kind, rp, ref) values (pid, 'chapter', gain * 30, p_ch || ':' || (old | s));
      update pilots set rp = rp + gain * 30, xp = xp + gain * 50, updated_at = now() where id = pid;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- a pilot's own campaign: twenty numbers, one per chapter
create or replace function public.my_chapters() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(coalesce(c.stars, 0) order by g.i), '[]'::jsonb)
  from generate_series(1, 20) g(i) left join chapter_stars c on c.pilot = auth.uid() and c.chapter = g.i;
$$;

revoke all on function public.chapter_n(int), public.chapter_report(text, int, jsonb), public.my_chapters() from public, anon, authenticated;
grant execute on function public.chapter_report(text, int, jsonb) to anon, authenticated;
grant execute on function public.my_chapters() to authenticated;
