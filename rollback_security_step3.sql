-- Rollback for security_step3_safe_text.sql. Removes the text checks; no data
-- changes. Only run if a legitimate save starts failing because of them.
begin;
alter table public.players                  drop constraint if exists players_safe_text;
alter table public.registrations            drop constraint if exists registrations_safe_text;
alter table public.posts                    drop constraint if exists posts_safe_text;
alter table public.post_comments            drop constraint if exists post_comments_safe_text;
alter table public.tournament_registrations drop constraint if exists tournament_registrations_safe_text;
alter table public.tournament_payments      drop constraint if exists tournament_payments_safe_text;
alter table public.dgroup_joins             drop constraint if exists dgroup_joins_safe_text;
drop function if exists public._safe_short(text);
drop function if exists public._safe_long(text);
drop function if exists public._safe_link(text);
commit;
