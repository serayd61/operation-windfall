-- claim_pilot referred to its own variable by the function's name, which Postgres only allows for parameters.
create or replace function public.claim_pilot(p_name text, p_code text) returns public.pilots language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.pilots; mine public.pilots; raw text := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')); nm text := lower(btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g')));
begin
  if v_uid is null then raise exception 'not_signed_in'; end if;
  delete from claim_tries t where t.at < now() - interval '1 day';
  if (select count(*) from claim_tries t where t.uid = v_uid and t.at > now() - interval '1 hour') >= 5 then raise exception 'too_many'; end if;
  select p.* into r from pilots p join pilot_secrets s on s.pilot = p.id
  where lower(p.name) = nm and s.recovery_hash = encode(sha256(convert_to(raw, 'UTF8')), 'hex') for update of p;
  if not found or char_length(raw) <> 16 then
    insert into claim_tries (uid) values (v_uid);
    return null;                                  -- the device reads "no pilot" as a wrong name or code
  end if;
  if r.id = v_uid then return r; end if;
  select * into mine from pilots p where p.id = v_uid for update;
  if found then
    if mine.sorties > 0 then raise exception 'has_pilot'; end if;
    delete from pilots p where p.id = v_uid;
  end if;
  delete from pilot_secrets s where s.pilot = r.id;
  update pilots p set id = v_uid, updated_at = now() where p.id = r.id returning * into r;
  insert into ledger (pilot, kind, ref) values (v_uid, 'claim', 'moved to a new device');
  delete from claim_tries t where t.uid = v_uid;
  return r;
end $$;
revoke all on function public.claim_pilot(text, text) from public, anon;
grant execute on function public.claim_pilot(text, text) to authenticated;
