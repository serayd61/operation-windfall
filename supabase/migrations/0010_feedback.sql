-- Feedback written inside the game. Rows are reachable only through send_feedback; nobody can read them from the client.
-- They hang on the account, so "Delete my pilot" (delete_me removes the auth user) removes them too.
create table if not exists public.feedback (
  id bigint generated always as identity primary key,
  uid uuid not null references auth.users(id) on delete cascade,
  name text,
  body text not null check (char_length(body) between 3 and 1000),
  lang text, build int, device text,
  created_at timestamptz not null default now()
);
alter table public.feedback enable row level security;
create index if not exists feedback_uid_at on public.feedback (uid, created_at);

create or replace function public.send_feedback(p_text text, p_lang text default null, p_build int default null, p_device text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); t text := btrim(coalesce(p_text, ''));
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  if char_length(t) < 3 or char_length(t) > 1000 then raise exception 'bad_text'; end if;
  if (select count(*) from feedback f where f.uid = v_uid and f.created_at > now() - interval '1 day') >= 5 then raise exception 'too_many'; end if;
  insert into feedback (uid, name, body, lang, build, device)
  values (v_uid, (select p.name from pilots p where p.id = v_uid), t, left(p_lang, 5), p_build, left(p_device, 200));
end $$;

revoke all on function public.send_feedback(text, text, int, text) from public, anon, authenticated;
grant execute on function public.send_feedback(text, text, int, text) to authenticated;
