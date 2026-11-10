-- Rollback for mpr_rating.sql
-- Restores the pre-MPR ratings, the old rating functions and the deleted
-- duplicate session row. Run the whole file in the Supabase SQL editor.

-- Ratings and match counts as they were before MPR
update public.players
   set rating_pickleball = rating_pickleball_v1,
       pickleball_matches = pickleball_matches_v1
 where rating_pickleball_v1 is not null or pickleball_matches_v1 is not null;

-- The duplicate Oct 5 row
insert into public.game_history (id, game_date, player_count, teams, matches, created_at, sport)
select id, game_date, player_count, teams, matches, created_at, sport
  from public.game_history_deleted where id = 'GH1791211059324'
on conflict (id) do nothing;

-- Old member_set_dupr (DUPR always re-seeds the played rating)
CREATE OR REPLACE FUNCTION public.member_set_dupr(p_phone text, p_pin text, p_dupr numeric)
 RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public', 'extensions'
AS $function$
DECLARE v_hash text; v_locked timestamptz;
BEGIN
  SELECT pin_hash, locked_until INTO v_hash, v_locked FROM players WHERE phone = p_phone AND is_active = true;
  IF NOT FOUND THEN RETURN false; END IF;
  IF v_locked IS NOT NULL AND v_locked > now() THEN RETURN false; END IF;
  IF v_hash IS NULL OR crypt(p_pin, v_hash) <> v_hash THEN RETURN false; END IF;
  IF p_dupr IS NULL THEN RETURN true; END IF;
  IF p_dupr < 2.0 OR p_dupr > 8.0 THEN RETURN false; END IF;
  UPDATE players SET dupr = p_dupr, rating_pickleball = p_dupr WHERE phone = p_phone;
  RETURN true;
END;
$function$;

-- Old admin_apply_rating: re-run section 7 of mpr_rating.sql WITHOUT the line
--   IF p_sport IN ('pickleball','badminton') THEN RETURN true; END IF;
-- (the rest of that function body is the original, unchanged).

drop function if exists public.admin_record_rated_match(text, text, text, text, text[], text[], int, int);
drop function if exists public.admin_void_rated_match(text, text, text);
drop function if exists public._mpr_rebuild(text);
drop function if exists public._mpr_apply(text);
drop function if exists public._mpr_seed(text);
drop table if exists public.rated_matches;
-- Backup columns rating_pickleball_v1 / pickleball_matches_v1 and table
-- game_history_deleted are left in place on purpose (harmless, useful record).
