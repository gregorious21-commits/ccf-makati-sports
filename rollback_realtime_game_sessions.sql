-- Rollback for realtime_game_sessions.sql. The app falls back to polling
-- every 8 seconds on its own when the realtime channel can't subscribe.
alter publication supabase_realtime drop table public.game_sessions;
