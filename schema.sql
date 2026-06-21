-- ════════════════════════════════════════════════════════════
--  CCF MAKATI SPORTS — Complete Supabase Schema
--  Run this in SQL Editor. Safe to re-run (uses IF NOT EXISTS).
-- ════════════════════════════════════════════════════════════

-- TABLES ─────────────────────────────────────────────────────

create table if not exists players (
  id            text primary key,
  first_name    text not null default '',
  last_name     text not null default '',
  phone         text unique not null,
  email         text default '',
  position      text default '',
  has_dgroup    boolean default false,
  dgroup_leader text default '',
  attended_ccf  boolean default false,
  waiver_signed boolean default false,
  pin           text default '',
  wins          integer default 0,
  games_played  integer default 0,
  is_first_game boolean default true,
  status        text default 'active',
  joined        text default '',
  created_at    timestamptz default now()
);

create table if not exists games (
  id            text primary key,
  date          text not null default '',
  label         text not null default '',
  game_time     text default '7:00 AM',
  venue         text default '',
  spots         integer default 20,
  fee           integer default 200,
  status        text default 'tbd',
  cancel_reason text default '',
  created_at    timestamptz default now()
);

create table if not exists registrations (
  id          text primary key,
  player_id   text not null default '',
  player_name text not null default '',
  phone       text default '',
  email       text default '',
  game_id     text not null default '',
  game_label  text default '',
  game_time   text default '',
  fee         integer default 200,
  pay_type    text default 'cash',
  ref_num     text default '',
  has_proof   boolean default false,
  proof_url   text default '',
  status      text default 'pending',
  registered  text default '',
  created_at  timestamptz default now()
);

create table if not exists devotion (
  id               integer primary key default 1,
  votd_ref         text default '',
  votd_text        text default '',
  votd_published   boolean default false,
  devotion_title   text default '',
  verse_ref        text default '',
  verse_text       text default '',
  q1               text default '',
  q2               text default '',
  devotion_text    text default '',
  dev_published    boolean default false,
  updated_at       timestamptz default now()
);
insert into devotion (id) values (1) on conflict (id) do nothing;

create table if not exists announcements (
  id         bigserial primary key,
  message    text not null default '',
  type       text default 'info',
  active     boolean default true,
  created_at timestamptz default now()
);

create table if not exists notifications (
  id         bigserial primary key,
  title      text default '',
  message    text default '',
  type       text default 'info',
  created_at timestamptz default now()
);

create table if not exists game_history (
  id           text primary key,
  game_date    text default '',
  player_count integer default 0,
  teams        jsonb default '[]',
  matches      jsonb default '[]',
  created_at   timestamptz default now()
);

create table if not exists payment_methods (
  id           bigserial primary key,
  sport        text    not null default 'basketball',
  label        text    not null,
  account_num  text    not null,
  account_name text    not null default '',
  active       boolean default true,
  sort_order   int     default 0,
  created_at   timestamptz default now()
);

-- ADD COLUMNS IF MISSING ─────────────────────────────────────
alter table players       add column if not exists attended_ccf  boolean default false;
alter table players       add column if not exists waiver_signed boolean default false;
alter table players       add column if not exists pin           text    default '';
alter table players       add column if not exists sports        text    default 'basketball';
alter table players       add column if not exists pickleball_skill text default '';
alter table registrations add column if not exists proof_url     text    default '';
alter table registrations add column if not exists paid          boolean default false;
alter table games         add column if not exists sport         text    default 'basketball';
alter table registrations add column if not exists sport         text    default 'basketball';
alter table game_history  add column if not exists sport         text    default 'basketball';

-- Seed default payment methods on a fresh DB (idempotent: only when the table is empty).
insert into payment_methods (sport, label, account_num, account_name, sort_order)
select * from (values
  ('basketball', 'GCash',   '09274179132', 'CCF Makati Sports', 1),
  ('basketball', 'PayMaya', '09274179132', 'CCF Makati Sports', 2)
) as v(sport, label, account_num, account_name, sort_order)
where not exists (select 1 from payment_methods);
alter table games         add column if not exists sport         text    default 'basketball';
alter table registrations add column if not exists sport         text    default 'basketball';
alter table game_history  add column if not exists sport         text    default 'basketball';

-- PERMISSIONS ────────────────────────────────────────────────
grant usage on schema public to anon, authenticated;
grant all privileges on all tables    in schema public to anon, authenticated;
grant all privileges on all sequences in schema public to anon, authenticated;

-- RLS: enable then open policy ───────────────────────────────
alter table players       enable row level security;
alter table games         enable row level security;
alter table registrations enable row level security;
alter table devotion      enable row level security;
alter table announcements enable row level security;
alter table notifications enable row level security;
alter table game_history  enable row level security;
alter table payment_methods enable row level security;

drop policy if exists "allow_all" on players;
drop policy if exists "allow_all" on games;
drop policy if exists "allow_all" on registrations;
drop policy if exists "allow_all" on devotion;
drop policy if exists "allow_all" on announcements;
drop policy if exists "allow_all" on notifications;
drop policy if exists "allow_all" on game_history;
drop policy if exists "allow_all" on payment_methods;

create policy "allow_all" on players       for all using (true) with check (true);
create policy "allow_all" on games         for all using (true) with check (true);
create policy "allow_all" on registrations for all using (true) with check (true);
create policy "allow_all" on devotion      for all using (true) with check (true);
create policy "allow_all" on announcements for all using (true) with check (true);
create policy "allow_all" on notifications for all using (true) with check (true);
create policy "allow_all" on game_history  for all using (true) with check (true);
create policy "allow_all" on payment_methods for all using (true) with check (true);

-- STORAGE BUCKET FOR PAYMENT SCREENSHOTS ─────────────────────
insert into storage.buckets (id, name, public)
values ('proofs', 'proofs', true)
on conflict (id) do update set public = true;

drop policy if exists "allow_all_proofs" on storage.objects;
create policy "allow_all_proofs" on storage.objects
  for all using (bucket_id = 'proofs') with check (bucket_id = 'proofs');
