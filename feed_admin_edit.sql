-- Feed: admin edit + photo, staff tag, "Edited" marker (2026-11-11)
-- Rollback: rollback_feed_admin_edit.sql

-- 1) Who posted as staff (drives the "Admin" tag in the Feed)
alter table public.posts add column if not exists author_staff boolean not null default false;
alter table public.posts add column if not exists edited_at timestamptz;
update public.posts p set author_staff = true
  from public.players pl
 where pl.id = p.author_id and pl.role in ('owner','manager','gdm','dgc') and p.author_staff = false;

create or replace function public._posts_set_staff()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.author_staff := exists (select 1 from players where id = new.author_id and role in ('owner','manager','gdm','dgc'));
  return new;
end $$;
revoke all on function public._posts_set_staff() from public, anon, authenticated;
drop trigger if exists posts_set_staff on public.posts;
create trigger posts_set_staff before insert on public.posts
  for each row execute function public._posts_set_staff();

-- 2) Create or edit a post (admins). p_post_id null/'' = new post.
--    Editing keeps the author, date, reactions and comments; it marks the post edited.
create or replace function public.admin_save_post(
  p_my_phone text, p_my_pin text, p_post_id text, p_body text,
  p_image_url text, p_is_public boolean, p_pinned boolean)
returns text language plpgsql security definer set search_path to 'public', 'extensions' as $$
declare v players%rowtype; v_id text; v_img text;
begin
  select * into v from players where phone = p_my_phone;
  if not found or v.pin_hash is null or v.pin_hash = '' then return null; end if;
  if v.locked_until is not null and v.locked_until > now() then return null; end if;
  if v.pin_hash <> crypt(p_my_pin, v.pin_hash) then return null; end if;
  if v.role not in ('manager','owner','dgc') then return null; end if;

  v_img := nullif(btrim(coalesce(p_image_url, '')), '');
  if v_img is not null and v_img !~ '^https://ogcgfrdiufvmzkdxogxd\.supabase\.co/storage/v1/object/public/' then return null; end if;
  if coalesce(btrim(p_body), '') = '' and v_img is null then return null; end if;
  if length(coalesce(p_body, '')) > 5000 then return null; end if;

  if coalesce(p_post_id, '') = '' then
    v_id := 'POST' || (extract(epoch from now()) * 1000)::bigint::text;
    insert into posts (id, body, author_id, author_name, image_url, is_public, pinned, status, created_at)
    values (v_id, coalesce(p_body, ''), v.id, v.first_name || ' ' || v.last_name, coalesce(v_img, ''),
            coalesce(p_is_public, false), coalesce(p_pinned, false), 'active', now());
  else
    update posts
       set body = coalesce(p_body, ''), image_url = coalesce(v_img, ''),
           is_public = coalesce(p_is_public, false), pinned = coalesce(p_pinned, false),
           edited_at = now()
     where id = p_post_id and status = 'active'
     returning id into v_id;
  end if;
  return v_id;
end $$;

-- 3) Re-create get_feed so it returns the new columns (same body as before)
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
