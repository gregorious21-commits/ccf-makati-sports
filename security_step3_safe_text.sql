-- Security step 3: block HTML/script characters in member-entered text.
-- Names, team names, notes and links typed by members are shown to everyone
-- (including admins). The apps build their screens from HTML strings, so a
-- name like <img onerror=...> would run as code. These checks make the
-- database refuse those characters on every write path (RPCs and admin).
--
-- Short fields (names, emails, positions, ref numbers):  no < > " ` \
-- Free text (bio, notes):                                  no < > ` \
-- Links (avatar, proof, post image):                       no < > " ' ` \ or spaces
-- Post and comment bodies are not restricted; the apps escape them.
--
-- Checked before writing: no existing row breaks these rules.
-- Rollback: rollback_security_step3.sql

begin;

create or replace function public._safe_short(t text) returns boolean
language sql immutable as $$ select t is null or t !~ '[<>"`\\]' $$;
create or replace function public._safe_long(t text) returns boolean
language sql immutable as $$ select t is null or t !~ '[<>`\\]' $$;
create or replace function public._safe_link(t text) returns boolean
language sql immutable as $$ select t is null or t !~ '[<>"''`\\[:space:]]' $$;

alter table public.players
  add constraint players_safe_text check (
    _safe_short(first_name) and _safe_short(last_name) and _safe_short(email)
    and _safe_short(position) and _safe_short(dgroup_leader) and _safe_short(sports)
    and _safe_short(pickleball_skill) and _safe_short(guardian_name)
    and _safe_short(guardian_contact) and _safe_short(church_affiliation)
    and _safe_long(bio) and _safe_link(avatar_url));

alter table public.registrations
  add constraint registrations_safe_text check (
    _safe_short(player_name) and _safe_short(email) and _safe_short(ref_num)
    and _safe_short(pay_type) and _safe_link(proof_url));

alter table public.posts
  add constraint posts_safe_text check (_safe_short(author_name) and _safe_link(image_url));

alter table public.post_comments
  add constraint post_comments_safe_text check (_safe_short(author_name));

alter table public.tournament_registrations
  add constraint tournament_registrations_safe_text check (
    _safe_short(team_name) and _safe_long(notes));

alter table public.tournament_payments
  add constraint tournament_payments_safe_text check (
    _safe_long(notes) and _safe_link(proof_url));

alter table public.dgroup_joins
  add constraint dgroup_joins_safe_text check (
    _safe_short(leader_name) and _safe_short(leader_mobile));

commit;
