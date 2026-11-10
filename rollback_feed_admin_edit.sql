-- Rollback for feed_admin_edit.sql
drop function if exists public.admin_save_post(text, text, text, text, text, boolean, boolean);
drop trigger if exists posts_set_staff on public.posts;
drop function if exists public._posts_set_staff();
alter table public.posts drop column if exists author_staff;
alter table public.posts drop column if exists edited_at;
-- get_feed: same body as before; re-run its definition so it returns the original columns
create or replace function public.get_feed(p_phone text, p_pin text)
 returns setof posts language plpgsql security definer set search_path to 'public', 'extensions' as $function$
declare v players%rowtype;
begin
  select * into v from players where phone=p_phone;
  if not found or v.pin_hash is null or v.pin_hash='' then return; end if;
  if v.locked_until is not null and v.locked_until>now() then return; end if;
  if v.pin_hash <> crypt(p_pin, v.pin_hash) then return; end if;
  return query select * from posts where status='active' order by pinned desc, created_at desc;
end; $function$;
