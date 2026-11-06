-- Rollback for security_step1_additive.sql. Restores the previous (insecure)
-- access so the old app code works again. Only run if step 1 breaks the
-- live site.
begin;

drop view if exists public.players_public;
create view public.players_public as
  select id, first_name, last_name, phone, email, "position", sports,
         pickleball_skill, has_dgroup, dgroup_leader, attended_ccf,
         waiver_signed, wins, games_played, joined, avatar_url, bio, dupr,
         rating_basketball, rating_pickleball, rating_badminton,
         pickleball_matches
    from public.players
   where is_active = true;
grant all on public.players_public to anon, authenticated;

drop view if exists public.registrations_public;
drop function if exists public.admin_list_registrations(text, text, boolean);

drop policy if exists announcements_public_read on public.announcements;
create policy allow_all on public.announcements for all to public using (true) with check (true);
grant insert, update, delete on public.announcements to anon, authenticated;

create policy allow_all on public.app_config for all to public using (true) with check (true);
grant all on public.app_config to anon, authenticated;

drop policy if exists payment_proofs_upload on storage.objects;
-- The payment-proofs bucket is left in place (it may hold files); delete it
-- from the Supabase dashboard if it is empty and no longer wanted.

commit;
