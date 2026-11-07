-- Live queue: send game-day session changes to members instantly (Supabase
-- Realtime) instead of every phone polling every 8 seconds.
-- The row is already publicly readable (policy game_sessions_public_read), so
-- this adds no new exposure. The `token` column is only a change marker the
-- admin uses to skip its own saves; writes still need an admin PIN.
-- Rollback: rollback_realtime_game_sessions.sql
alter publication supabase_realtime add table public.game_sessions;
