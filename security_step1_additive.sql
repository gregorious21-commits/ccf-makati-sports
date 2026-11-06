-- Security step 1 (additive / backward compatible with the live site).
-- Applied before the redesign merge. Rollback: rollback_security_step1.sql
--
-- 1. players_public: drop phone + email, make it read-only (it was
--    auto-updatable, so anon could UPDATE/INSERT players through it).
-- 2. registrations_public: the columns the member app needs, without
--    phone, email, payment proof link, reference number or payment type.
-- 3. admin_list_registrations(): full rows for admin roles (PIN-checked).
-- 4. announcements: read-only for the public key (writes already go through
--    admin_create_announcement / admin_deactivate_announcement).
-- 5. app_config: no public access (only the legacy shared admin PIN lives
--    here; admin_update_admin_pin is SECURITY DEFINER).
-- 6. payment-proofs: new private bucket; the public key may upload new
--    proofs but cannot list, read, overwrite or delete them.

begin;

-- 1 ─────────────────────────────────────────────────────────────
drop view if exists public.players_public;
create view public.players_public with (security_barrier = true) as
  select id, first_name, last_name, "position", sports, pickleball_skill,
         has_dgroup, dgroup_leader, attended_ccf, waiver_signed, wins,
         games_played, joined, avatar_url, bio, dupr, rating_basketball,
         rating_pickleball, rating_badminton, pickleball_matches
    from public.players
   where is_active = true;
revoke all on public.players_public from public, anon, authenticated;
grant select on public.players_public to anon, authenticated;

-- 2 ─────────────────────────────────────────────────────────────
create or replace view public.registrations_public with (security_barrier = true) as
  select id, player_id, player_name, game_id, game_label, sport, status,
         registered, created_at, attended, attended_at
    from public.registrations;
revoke all on public.registrations_public from public, anon, authenticated;
grant select on public.registrations_public to anon, authenticated;

-- 3 ─────────────────────────────────────────────────────────────
create or replace function public.admin_list_registrations(
  p_my_phone text, p_my_pin text, p_include_cancelled boolean default false)
returns setof public.registrations
language plpgsql security definer
set search_path to 'public', 'extensions'
as $$
begin
  if not public._verify_admin(p_my_phone, p_my_pin) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
  return query
    select * from public.registrations
     where p_include_cancelled or status <> 'cancelled'
     order by created_at desc;
end;
$$;
revoke all on function public.admin_list_registrations(text, text, boolean) from public;
grant execute on function public.admin_list_registrations(text, text, boolean) to anon, authenticated;

-- 4 ─────────────────────────────────────────────────────────────
drop policy if exists allow_all on public.announcements;
create policy announcements_public_read on public.announcements
  for select to anon, authenticated using (true);
revoke insert, update, delete, truncate on public.announcements from anon, authenticated;

-- 5 ─────────────────────────────────────────────────────────────
drop policy if exists allow_all on public.app_config;
revoke all on public.app_config from anon, authenticated;

-- 6 ─────────────────────────────────────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','image/heif'])
on conflict (id) do update set public = false;

drop policy if exists payment_proofs_upload on storage.objects;
create policy payment_proofs_upload on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'payment-proofs'
              and name ~ '^(reg|tourn)-[A-Za-z0-9_-]+\.(jpg|jpeg|png|webp|heic|heif)$');

commit;
