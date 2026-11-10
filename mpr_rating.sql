-- MPR (Makati Pickleball Rating), 2026-11-11
--
-- Replaces the old pickleball/badminton update inside admin_apply_rating with a
-- DUPR-style, score-based rating:
--   * Each team's rating = average of its players.
--   * Expected share of points for team A: 1 / (1 + 10^(-(Ra - Rb) / 2.0)).
--   * Each player moves by  k * (actual point share - expected share).
--     A win by less than expected can lower a rating; a close loss to a
--     stronger team can raise it (zero-sum within the match).
--   * k (learning rate) shrinks as the player logs matches:
--       k = 0.35 + (0.90 - 0.35) * 8 / (8 + matches_before)
--   * Range 2.000 to 8.000.
--   * Starting value: self-entered DUPR, else by profile skill
--       newbie 2.5 / intermediate 3.0 / expert 3.5 / unknown 2.75.
-- Parameters were tuned by replaying the 468 saved matches (after removing
-- the duplicate Oct 5 copy).
--
-- Every rated match is stored in rated_matches with each player's rating
-- before/after, so ratings can be rebuilt, a wrong score can be fixed, and a
-- retried request never counts twice (match id is the primary key).
--
-- Rollback: rollback_mpr_rating.sql

-- 0) Backup of today's ratings (kept for rollback/comparison)
alter table public.players add column if not exists rating_pickleball_v1 numeric(5,3);
alter table public.players add column if not exists pickleball_matches_v1 integer;
update public.players
   set rating_pickleball_v1 = rating_pickleball,
       pickleball_matches_v1 = pickleball_matches
 where rating_pickleball_v1 is null and pickleball_matches_v1 is null;

-- 0b) Remove the duplicate Oct 5 pickleball session (an exact copy of
--     GH1791211445142, re-saved on Oct 19 from a stale "failed save" backup).
--     Kept in game_history_deleted so it can be restored.
create table if not exists public.game_history_deleted (like public.game_history including all);
alter table public.game_history_deleted add column if not exists deleted_at timestamptz default now();
alter table public.game_history_deleted enable row level security;
insert into public.game_history_deleted (id, game_date, player_count, teams, matches, created_at, sport)
  select id, game_date, player_count, teams, matches, created_at, sport from public.game_history
   where id = 'GH1791211059324'
     and matches = (select matches from public.game_history where id = 'GH1791211445142')
  on conflict (id) do nothing;
delete from public.game_history g
 where g.id = 'GH1791211059324'
   and exists (select 1 from public.game_history_deleted d where d.id = g.id);

-- 1) The ledger
create table if not exists public.rated_matches (
  id           text primary key,
  sport        text not null check (sport in ('pickleball','badminton')),
  team_a       text[] not null check (cardinality(team_a) between 1 and 2),
  team_b       text[] not null check (cardinality(team_b) between 1 and 2),
  score_a      integer not null check (score_a between 0 and 99),
  score_b      integer not null check (score_b between 0 and 99),
  played_at    timestamptz not null default now(),
  source       text not null default 'live' check (source in ('live','history')),
  history_id   text,
  ratings      jsonb,              -- { "<player id>": {"before": 3.012, "after": 3.088}, ... }
  recorded_by  text,
  voided_at    timestamptz,
  voided_by    text,
  created_at   timestamptz not null default now(),
  check (score_a <> score_b),
  check (score_a + score_b > 0)
);
alter table public.rated_matches enable row level security;   -- no policies: only the functions below touch it
create index if not exists rated_matches_sport_played on public.rated_matches (sport, played_at, id);
create index if not exists rated_matches_team_a on public.rated_matches using gin (team_a);
create index if not exists rated_matches_team_b on public.rated_matches using gin (team_b);

-- 2) Starting rating for a player who has never been rated
create or replace function public._mpr_seed(p_id text)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(
    (select dupr from players where id = p_id),
    case lower(coalesce((select pickleball_skill from players where id = p_id), ''))
      when 'newbie' then 2.5 when 'beginner' then 2.5
      when 'intermediate' then 3.0
      when 'expert' then 3.5 when 'advanced' then 3.5
      else 2.75 end)
$$;

-- 3) Apply one stored match to the players' ratings (internal)
create or replace function public._mpr_apply(p_match_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  m        rated_matches%rowtype;
  v_col    text;
  v_pid    text;
  v_cur    numeric;
  v_n      int;
  v_ra     numeric := 0;
  v_rb     numeric := 0;
  v_exp_a  numeric;
  v_share  numeric;
  v_k      numeric;
  v_new    numeric;
  v_before jsonb := '{}'::jsonb;
  v_out    jsonb := '{}'::jsonb;
begin
  select * into m from rated_matches where id = p_match_id;
  if not found or m.voided_at is not null then return null; end if;
  v_col := case m.sport when 'pickleball' then 'rating_pickleball' else 'rating_badminton' end;

  -- current ratings (locked so two courts finishing together can't clash)
  foreach v_pid in array (m.team_a || m.team_b) loop
    execute format('select %I from players where id = $1 for update', v_col) into v_cur using v_pid;
    v_before := v_before || jsonb_build_object(v_pid, coalesce(v_cur, _mpr_seed(v_pid)));
  end loop;
  select avg((v_before->>x)::numeric) into v_ra from unnest(m.team_a) x;
  select avg((v_before->>x)::numeric) into v_rb from unnest(m.team_b) x;

  v_exp_a := 1.0 / (1.0 + power(10.0, -(v_ra - v_rb) / 2.0));
  v_share := m.score_a::numeric / (m.score_a + m.score_b);

  foreach v_pid in array (m.team_a || m.team_b) loop
    -- matches this player had before this one
    select count(*) into v_n from rated_matches r
     where r.sport = m.sport and r.voided_at is null
       and (r.played_at, r.id) < (m.played_at, m.id)
       and (r.team_a @> array[v_pid] or r.team_b @> array[v_pid]);
    v_k := 0.35 + (0.90 - 0.35) * 8.0 / (8.0 + v_n);
    v_cur := (v_before->>v_pid)::numeric;
    v_new := v_cur + v_k * (case when v_pid = any(m.team_a) then 1 else -1 end) * (v_share - v_exp_a);
    v_new := round(greatest(2.0, least(8.0, v_new)), 3);
    execute format('update players set %I = $1 where id = $2', v_col) using v_new, v_pid;
    if m.sport = 'pickleball' then
      update players set pickleball_matches = v_n + 1 where id = v_pid;
    end if;
    v_out := v_out || jsonb_build_object(v_pid, jsonb_build_object('before', round(v_cur,3), 'after', v_new));
  end loop;

  update rated_matches set ratings = v_out where id = p_match_id;
  return v_out;
end $$;
revoke all on function public._mpr_apply(text) from public, anon, authenticated;
revoke all on function public._mpr_seed(text) from public, anon, authenticated;

-- 4) Record a match (admin / game day managers). Safe to retry: same id = no double count.
create or replace function public.admin_record_rated_match(
  p_my_phone text, p_my_pin text, p_id text, p_sport text,
  p_team_a text[], p_team_b text[], p_score_a int, p_score_b int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_me text; v_existing jsonb;
begin
  if not _verify_admin(p_my_phone, p_my_pin) then return null; end if;
  if p_sport not in ('pickleball','badminton') then return null; end if;
  if p_id is null or length(p_id) > 80 then return null; end if;
  if cardinality(p_team_a) not between 1 and 2 or cardinality(p_team_b) <> cardinality(p_team_a) then return null; end if;
  if p_team_a && p_team_b then return null; end if;
  if p_score_a is null or p_score_b is null or p_score_a = p_score_b
     or p_score_a not between 0 and 99 or p_score_b not between 0 and 99 then return null; end if;

  select ratings into v_existing from rated_matches where id = p_id;
  if found then return coalesce(v_existing, '{}'::jsonb); end if;   -- already recorded

  select id into v_me from players where phone = p_my_phone;
  insert into rated_matches (id, sport, team_a, team_b, score_a, score_b, recorded_by)
  values (p_id, p_sport, p_team_a, p_team_b, p_score_a, p_score_b, v_me);
  return _mpr_apply(p_id);
end $$;

-- 5) Void a match (used by "Fix score": void the wrong one, record the right one)
create or replace function public.admin_void_rated_match(p_my_phone text, p_my_pin text, p_id text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare m rated_matches%rowtype; v_col text; v_pid text; v_cur numeric; v_delta numeric; v_me text;
begin
  if not _verify_admin(p_my_phone, p_my_pin) then return false; end if;
  select * into m from rated_matches where id = p_id for update;
  if not found then return false; end if;
  if m.voided_at is not null then return true; end if;
  v_col := case m.sport when 'pickleball' then 'rating_pickleball' else 'rating_badminton' end;
  -- take back exactly what this match gave/took
  for v_pid in select jsonb_object_keys(coalesce(m.ratings, '{}'::jsonb)) loop
    v_delta := (m.ratings->v_pid->>'after')::numeric - (m.ratings->v_pid->>'before')::numeric;
    execute format('select %I from players where id = $1 for update', v_col) into v_cur using v_pid;
    if v_cur is not null then
      execute format('update players set %I = $1 where id = $2', v_col)
        using round(greatest(2.0, least(8.0, v_cur - v_delta)), 3), v_pid;
    end if;
    if m.sport = 'pickleball' then
      update players set pickleball_matches = greatest(coalesce(pickleball_matches,0) - 1, 0) where id = v_pid;
    end if;
  end loop;
  select id into v_me from players where phone = p_my_phone;
  update rated_matches set voided_at = now(), voided_by = v_me where id = p_id;
  return true;
end $$;

-- 6) Rebuild every rating of a sport from the ledger, oldest match first
create or replace function public._mpr_rebuild(p_sport text)
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_count int := 0;
begin
  if p_sport = 'pickleball' then
    update players set rating_pickleball = dupr, pickleball_matches = 0
     where rating_pickleball is not null or coalesce(pickleball_matches,0) > 0 or dupr is not null;
  elsif p_sport = 'badminton' then
    update players set rating_badminton = null where rating_badminton is not null;
  else
    return 0;
  end if;
  for r in select id from rated_matches where sport = p_sport and voided_at is null order by played_at, id loop
    perform _mpr_apply(r.id); v_count := v_count + 1;
  end loop;
  return v_count;
end $$;
revoke all on function public._mpr_rebuild(text) from public, anon, authenticated;

-- 7) Old function: pickleball/badminton now go through admin_record_rated_match.
--    A stale admin page calling the old path must not apply the old formula.
--    Basketball is unchanged (body below is the original, plus one guard line).
CREATE OR REPLACE FUNCTION public.admin_apply_rating(p_my_phone text, p_my_pin text, p_sport text, p_winner_ids text[], p_loser_ids text[], p_score_winner integer DEFAULT NULL::integer, p_score_loser integer DEFAULT NULL::integer)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_col            text;
  v_pid            text;
  v_rating         numeric;
  v_games          int;
  v_avg_win        numeric := 0;
  v_avg_lose       numeric := 0;
  v_count          int;
  v_k              numeric;
  v_margin_mult    numeric := 1.0;
  v_expected_win   numeric;
  v_expected_lose  numeric;
  v_delta          numeric;
  v_new_rating     numeric;
  v_default_rating numeric;
BEGIN
  IF NOT _verify_admin(p_my_phone, p_my_pin) THEN RETURN false; END IF;
  IF p_sport IN ('pickleball','badminton') THEN RETURN true; END IF;   -- MPR: see admin_record_rated_match

  v_col := CASE p_sport
    WHEN 'basketball'  THEN 'rating_basketball'
    WHEN 'pickleball'  THEN 'rating_pickleball'
    WHEN 'badminton'   THEN 'rating_badminton'
    ELSE NULL
  END;
  IF v_col IS NULL THEN RETURN false; END IF;

  v_default_rating := 2.5;  -- unrated players start at "advanced beginner"

  -- Team average ratings
  v_avg_win := 0; v_count := 0;
  FOREACH v_pid IN ARRAY p_winner_ids LOOP
    SELECT COALESCE(
      CASE v_col WHEN 'rating_basketball' THEN rating_basketball
                 WHEN 'rating_pickleball' THEN rating_pickleball
                 WHEN 'rating_badminton'  THEN rating_badminton END,
      COALESCE(dupr, v_default_rating)
    ) INTO v_rating FROM players WHERE id = v_pid;
    IF FOUND THEN v_avg_win := v_avg_win + COALESCE(v_rating, v_default_rating); v_count := v_count + 1; END IF;
  END LOOP;
  IF v_count > 0 THEN v_avg_win := v_avg_win / v_count; ELSE v_avg_win := v_default_rating; END IF;

  v_avg_lose := 0; v_count := 0;
  FOREACH v_pid IN ARRAY p_loser_ids LOOP
    SELECT COALESCE(
      CASE v_col WHEN 'rating_basketball' THEN rating_basketball
                 WHEN 'rating_pickleball' THEN rating_pickleball
                 WHEN 'rating_badminton'  THEN rating_badminton END,
      COALESCE(dupr, v_default_rating)
    ) INTO v_rating FROM players WHERE id = v_pid;
    IF FOUND THEN v_avg_lose := v_avg_lose + COALESCE(v_rating, v_default_rating); v_count := v_count + 1; END IF;
  END LOOP;
  IF v_count > 0 THEN v_avg_lose := v_avg_lose / v_count; ELSE v_avg_lose := v_default_rating; END IF;

  -- Score-margin multiplier
  IF p_score_winner IS NOT NULL AND p_score_loser IS NOT NULL AND p_score_winner > 0 THEN
    v_margin_mult := GREATEST(p_score_winner::numeric, 11.0) / GREATEST(p_score_loser::numeric + 3.0, 5.0);
    v_margin_mult := GREATEST(1.0, LEAST(v_margin_mult, 2.0));
  END IF;

  v_expected_win  := 1.0 / (1.0 + power(10.0, (v_avg_lose - v_avg_win) / 8.0));
  v_expected_lose := 1.0 - v_expected_win;

  -- Winners
  FOREACH v_pid IN ARRAY p_winner_ids LOOP
    SELECT COALESCE(
      CASE v_col WHEN 'rating_basketball' THEN rating_basketball
                 WHEN 'rating_pickleball' THEN rating_pickleball
                 WHEN 'rating_badminton'  THEN rating_badminton END,
      COALESCE(dupr, v_default_rating)
    ), COALESCE(games_played, 0)
    INTO v_rating, v_games FROM players WHERE id = v_pid;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_k := CASE WHEN v_games < 5 THEN 0.32 WHEN v_games < 15 THEN 0.24 WHEN v_games < 30 THEN 0.16 ELSE 0.08 END;
    v_delta      := v_k * v_margin_mult * (1.0 - v_expected_win);
    v_new_rating := ROUND(GREATEST(2.0, LEAST(8.0, COALESCE(v_rating, v_default_rating) + v_delta))::numeric, 2);
    EXECUTE format('UPDATE players SET %I = $1 WHERE id = $2', v_col) USING v_new_rating, v_pid;
  END LOOP;

  -- Losers
  FOREACH v_pid IN ARRAY p_loser_ids LOOP
    SELECT COALESCE(
      CASE v_col WHEN 'rating_basketball' THEN rating_basketball
                 WHEN 'rating_pickleball' THEN rating_pickleball
                 WHEN 'rating_badminton'  THEN rating_badminton END,
      COALESCE(dupr, v_default_rating)
    ), COALESCE(games_played, 0)
    INTO v_rating, v_games FROM players WHERE id = v_pid;
    IF NOT FOUND THEN CONTINUE; END IF;

    v_k := CASE WHEN v_games < 5 THEN 0.32 WHEN v_games < 15 THEN 0.24 WHEN v_games < 30 THEN 0.16 ELSE 0.08 END;
    v_delta      := v_k * v_margin_mult * (0.0 - v_expected_lose);
    v_new_rating := ROUND(GREATEST(2.0, LEAST(8.0, COALESCE(v_rating, v_default_rating) + v_delta))::numeric, 2);
    EXECUTE format('UPDATE players SET %I = $1 WHERE id = $2', v_col) USING v_new_rating, v_pid;
  END LOOP;

  -- Bump the pickleball match counter for everyone who played (provisional logic)
  IF p_sport = 'pickleball' THEN
    UPDATE players SET pickleball_matches = COALESCE(pickleball_matches,0) + 1
     WHERE id = ANY(p_winner_ids) OR id = ANY(p_loser_ids);
  END IF;

  RETURN true;
END;
$function$;

-- 8) A self-entered DUPR only sets the STARTING MPR (before any rated match).
create or replace function public.member_set_dupr(p_phone text, p_pin text, p_dupr numeric)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text; v_locked timestamptz;
begin
  select pin_hash, locked_until into v_hash, v_locked from players where phone = p_phone and is_active = true;
  if not found then return false; end if;
  if v_locked is not null and v_locked > now() then return false; end if;
  if v_hash is null or crypt(p_pin, v_hash) <> v_hash then return false; end if;
  if p_dupr is null then return true; end if;
  if p_dupr < 2.0 or p_dupr > 8.0 then return false; end if;
  update players
     set dupr = p_dupr,
         rating_pickleball = case when coalesce(pickleball_matches, 0) = 0 then p_dupr else rating_pickleball end
   where phone = p_phone;
  return true;
end $$;

-- 9) Fill the ledger from saved history (oldest session first), then rebuild.
insert into public.rated_matches (id, sport, team_a, team_b, score_a, score_b, played_at, source, history_id)
select h.id || '-' || (e.ord - 1),
       h.sport,
       array(select jsonb_array_elements_text(e.m->'teamA')),
       array(select jsonb_array_elements_text(e.m->'teamB')),
       (e.m->>'scoreA')::int, (e.m->>'scoreB')::int,
       h.created_at + make_interval(secs => e.ord),
       'history', h.id
  from public.game_history h
  cross join lateral jsonb_array_elements(coalesce(h.matches, '[]'::jsonb)) with ordinality as e(m, ord)
 where h.sport in ('pickleball','badminton')
   and (e.m->>'scoreA') is not null and (e.m->>'scoreB') is not null
   and (e.m->>'scoreA')::int <> (e.m->>'scoreB')::int
   and jsonb_array_length(e.m->'teamA') between 1 and 2
   and jsonb_array_length(e.m->'teamA') = jsonb_array_length(e.m->'teamB')
on conflict (id) do nothing;

select public._mpr_rebuild('pickleball') as pickleball_matches_replayed;
