-- Security step 2 (lockdown). Run right after the redesign/light merge,
-- once the new app code (which reads registrations_public and
-- admin_list_registrations) is live. The OLD code breaks after this.
-- Then run the migrate-proofs edge function (dry:false) to move payment
-- screenshots into the private bucket.
-- Rollback: rollback_security_step2.sql

begin;

-- A. Registrations: no direct reads with the public key. The member app uses
--    registrations_public; admin uses admin_list_registrations(). Writes
--    already go through SECURITY DEFINER functions.
drop policy if exists registrations_own_read on public.registrations;
revoke all on public.registrations from anon, authenticated;

-- B. "proofs" bucket (avatars + feed photos): the public key may upload new
--    files with the app's naming, but can no longer list, overwrite or
--    delete anything. Public URLs keep working (public bucket).
drop policy if exists allow_all_proofs on storage.objects;
create policy proofs_upload on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'proofs'
              and name ~ '^(avatar-[A-Za-z0-9_-]+|post_[0-9]+_[a-z0-9]+)\.jpg$');

-- C. PIN helpers count wrong PINs like the login screen does (5 tries, then
--    15 minutes locked), so a PIN can't be guessed through admin or member
--    actions. Correct PINs behave exactly as before.
create or replace function public._verify_admin(p_phone text, p_pin text)
returns boolean language plpgsql security definer
set search_path to 'public', 'extensions'
as $function$
declare v_id text; v_hash text; v_locked timestamptz; v_role text;
begin
  select id, pin_hash, locked_until, role into v_id, v_hash, v_locked, v_role
    from players where phone = p_phone;
  if not found then return false; end if;
  if v_locked is not null and v_locked > now() then return false; end if;
  if coalesce(v_role, 'member') not in ('owner', 'manager', 'gdm', 'dgc') then return false; end if;
  if v_hash is not null and crypt(p_pin, v_hash) = v_hash then return true; end if;
  update players set
    failed_attempts = coalesce(failed_attempts, 0) + 1,
    locked_until = case when coalesce(failed_attempts, 0) + 1 >= 5
                        then now() + interval '15 minutes' else locked_until end
   where id = v_id;
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
  if not found or coalesce(v.pin_hash, '') = '' then return null; end if;
  if v.locked_until is not null and v.locked_until > now() then return null; end if;
  if v.pin_hash = crypt(p_pin, v.pin_hash) then return v.id; end if;
  update players set
    failed_attempts = coalesce(failed_attempts, 0) + 1,
    locked_until = case when coalesce(failed_attempts, 0) + 1 >= 5
                        then now() + interval '15 minutes' else locked_until end
   where id = v.id;
  return null;
end;
$function$;

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
  if v_player.pin_hash <> crypt(p_pin, v_player.pin_hash) then
    update players set
      failed_attempts = coalesce(failed_attempts, 0) + 1,
      locked_until = case when coalesce(failed_attempts, 0) + 1 >= 5
                          then now() + interval '15 minutes' else locked_until end
     where id = v_player.id;
    return null;
  end if;
  if coalesce(v_player.role, 'member') not in ('owner', 'manager', 'dgc') then return null; end if;
  return v_player;
end;
$function$;

-- D. The helpers are only meant to be called inside other functions.
revoke execute on function public._verify_admin(text, text) from public, anon, authenticated;
revoke execute on function public._member_id(text, text) from public, anon, authenticated;
revoke execute on function public._is_admin_caller(text, text) from public, anon, authenticated;
revoke execute on function public._tourn_admin_id(text, text) from public, anon, authenticated;
grant execute on function public._verify_admin(text, text) to service_role;
grant execute on function public._member_id(text, text) to service_role;

commit;
