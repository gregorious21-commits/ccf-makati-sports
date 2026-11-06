-- Rollback for security_step2_lockdown.sql. Restores public reads of
-- registrations, the open "proofs" storage policy and the old PIN helpers
-- (no wrong-PIN counting). Payment screenshots already moved by
-- migrate-proofs stay in the private bucket; old app code cannot show them.
begin;

create policy registrations_own_read on public.registrations for select to anon using (true);
grant select, insert, update, delete on public.registrations to anon, authenticated;

drop policy if exists proofs_upload on storage.objects;
create policy allow_all_proofs on storage.objects for all to anon, authenticated
  using (bucket_id = 'proofs') with check (bucket_id = 'proofs');

create or replace function public._verify_admin(p_phone text, p_pin text)
returns boolean language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_hash text; v_locked timestamptz; v_role text;
begin
  select pin_hash, locked_until, role into v_hash, v_locked, v_role from players where phone = p_phone;
  if not found then return false; end if;
  if v_locked is not null and v_locked > now() then return false; end if;
  if coalesce(v_role, 'member') not in ('owner', 'manager', 'gdm', 'dgc') then return false; end if;
  if v_hash is not null and crypt(p_pin, v_hash) = v_hash then return true; end if;
  return false;
end;
$function$;

create or replace function public._member_id(p_phone text, p_pin text)
returns text language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v players%rowtype;
begin
  select * into v from players where phone = p_phone;
  if not found or coalesce(v.pin_hash,'') = '' then return null; end if;
  if v.locked_until is not null and v.locked_until > now() then return null; end if;
  if v.pin_hash <> crypt(p_pin, v.pin_hash) then return null; end if;
  return v.id;
end; $function$;

create or replace function public._is_admin_caller(p_phone text, p_pin text)
returns players language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_player players%rowtype;
begin
  if p_phone is null or p_pin is null then return null; end if;
  select * into v_player from players where players.phone = p_phone;
  if not found then return null; end if;
  if v_player.locked_until is not null and v_player.locked_until > now() then return null; end if;
  if v_player.pin_hash is null or v_player.pin_hash = '' then return null; end if;
  if v_player.pin_hash <> crypt(p_pin, v_player.pin_hash) then return null; end if;
  if coalesce(v_player.role, 'member') not in ('owner','manager','dgc') then return null; end if;
  return v_player;
end;
$function$;

grant execute on function public._verify_admin(text, text) to public;
grant execute on function public._member_id(text, text) to public;
grant execute on function public._is_admin_caller(text, text) to public;
grant execute on function public._tourn_admin_id(text, text) to public;

commit;
