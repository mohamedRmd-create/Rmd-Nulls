-- Rmd Null: secure verification workflow
-- Run this in Supabase SQL Editor.

-- 1) Player verification flag.
alter table public.players add column if not exists verified boolean;
alter table public.players add column if not exists verified_at timestamptz;

-- Existing players remain public/verified; newly created players default to false.
update public.players set verified = true where verified is null;
alter table public.players alter column verified set default false;
alter table public.players alter column verified set not null;

-- 2) Verification request review fields.
alter table public.verification_requests add column if not exists admin_notes text;
alter table public.verification_requests add column if not exists rejection_reason text;
alter table public.verification_requests add column if not exists reviewed_at timestamptz;
alter table public.verification_requests add column if not exists reviewed_by uuid references auth.users(id);

-- Keep only one pending request per user.
create unique index if not exists verification_requests_one_pending_per_user
on public.verification_requests(user_id)
where status = 'pending';

-- 3) Private storage bucket for proof images.
insert into storage.buckets (id, name, public)
values ('verification-docs', 'verification-docs', false)
on conflict (id) do update set public = false;

-- 4) Admin helper: role must be in app_metadata, not user_metadata.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((auth.jwt() -> 'app_metadata' ->> 'role') = 'admin', false);
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

-- 5) Verification request RLS.
alter table public.verification_requests enable row level security;

-- Remove only policies with these exact names so this script is safe to re-run.
drop policy if exists "verification_requests_select_own_or_admin" on public.verification_requests;
drop policy if exists "verification_requests_insert_own" on public.verification_requests;
drop policy if exists "verification_requests_update_admin" on public.verification_requests;

create policy "verification_requests_select_own_or_admin"
on public.verification_requests for select to authenticated
using (auth.uid() = user_id or public.is_admin());

create policy "verification_requests_insert_own"
on public.verification_requests for insert to authenticated
with check (auth.uid() = user_id and status = 'pending');

create policy "verification_requests_update_admin"
on public.verification_requests for update to authenticated
using (public.is_admin())
with check (public.is_admin());

-- 6) Protect the verified flag from non-admin users.
-- This is important if another existing UPDATE policy lets a user edit their own player row.
create or replace function public.protect_player_verification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() and new.verified is distinct from old.verified then
    raise exception 'Only an admin can change player verification status';
  end if;
  if not public.is_admin() and new.verified_at is distinct from old.verified_at then
    raise exception 'Only an admin can change player verification timestamp';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_player_verification on public.players;
create trigger protect_player_verification
before update on public.players
for each row execute function public.protect_player_verification();

-- 7) Allow admins to update player verification.
alter table public.players enable row level security;
drop policy if exists "players_admin_select_all" on public.players;
create policy "players_admin_select_all"
on public.players for select to authenticated
using (public.is_admin());

drop policy if exists "players_admin_update_verification" on public.players;
create policy "players_admin_update_verification"
on public.players for update to authenticated
using (public.is_admin())
with check (public.is_admin());

-- 8) Storage RLS: users can upload/read their own proof files; admins can read all.
drop policy if exists "verification_docs_insert_own" on storage.objects;
drop policy if exists "verification_docs_select_own_or_admin" on storage.objects;


create policy "verification_docs_insert_own"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'verification-docs'
  and (storage.foldername(name))[1] = (select auth.uid()::text)
);

create policy "verification_docs_select_own_or_admin"
on storage.objects for select to authenticated
using (
  bucket_id = 'verification-docs'
  and ((storage.foldername(name))[1] = (select auth.uid()::text) or public.is_admin())
);

-- IMPORTANT: set your admin account's app_metadata role using a trusted admin/server context.
-- Do NOT put a service_role key in your website frontend.
-- Example (run only as a privileged SQL editor user, replacing the UUID):
-- update auth.users
-- set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role":"admin"}'::jsonb
-- where id = 'YOUR-AUTH-USER-UUID';

-- 8) Store the verified data submitted by the player in the player profile.
alter table public.players add column if not exists player_tag text;
alter table public.players add column if not exists social_username text;
alter table public.players add column if not exists account_created_date date;

-- 9) Secure, atomic admin review function.
-- On approval, the submitted verification data is copied to the player's profile
-- in the same database transaction as changing the request status.
create or replace function public.admin_review_verification_request(
  p_request_id uuid,
  p_status text,
  p_admin_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.verification_requests%rowtype;
  v_reviewed_at timestamptz := now();
begin
  if not public.is_admin() then
    raise exception 'Only admins can review verification requests';
  end if;

  if p_status not in ('approved','rejected') then
    raise exception 'Invalid review status';
  end if;

  select * into v_request
  from public.verification_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Verification request not found';
  end if;

  if p_status = 'approved' then
    update public.players
    set player_tag = v_request.player_tag,
        social_username = v_request.social_username,
        wins = v_request.wins,
        account_created_date = v_request.account_created_date::date,
        verified = true,
        verified_at = v_reviewed_at
    where user_id = v_request.user_id;

    if not found then
      raise exception 'Player profile not found for this verification request';
    end if;
  end if;

  update public.verification_requests
  set status = p_status,
      admin_notes = p_admin_notes,
      rejection_reason = case when p_status = 'rejected' then p_admin_notes else null end,
      reviewed_at = v_reviewed_at,
      reviewed_by = auth.uid()
  where id = p_request_id;

  return jsonb_build_object(
    'success', true,
    'status', p_status,
    'user_id', v_request.user_id
  );
end;
$$;

revoke all on function public.admin_review_verification_request(uuid,text,text) from public;
grant execute on function public.admin_review_verification_request(uuid,text,text) to authenticated;

-- 10) Protect verified profile fields from direct client-side manipulation.
-- Only the admin review function/admin session may change these fields.
create or replace function public.protect_player_verification()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    if new.verified is distinct from old.verified then
      raise exception 'Only an admin can change player verification status';
    end if;
    if new.verified_at is distinct from old.verified_at then
      raise exception 'Only an admin can change player verification timestamp';
    end if;
    if new.player_tag is distinct from old.player_tag then
      raise exception 'Only an admin can change the verified Player Tag';
    end if;
    if new.social_username is distinct from old.social_username then
      raise exception 'Only an admin can change the verified social username';
    end if;
    if new.account_created_date is distinct from old.account_created_date then
      raise exception 'Only an admin can change the verified account creation date';
    end if;
    if new.wins is distinct from old.wins then
      raise exception 'Only an admin can change the verified wins value';
    end if;
  end if;
  return new;
end;
$$;

-- Re-create the trigger so it uses the expanded protection above.
drop trigger if exists protect_player_verification on public.players;
create trigger protect_player_verification
before update on public.players
for each row execute function public.protect_player_verification();


-- 11) Badge system used by the public site and Admin Dashboard.
-- Safe to run even if these objects already exist.
create table if not exists public.badges (
  id text primary key,
  name text not null,
  icon text not null,
  title text not null,
  created_at timestamptz not null default now()
);

insert into public.badges (id,name,icon,title) values
('season_champion','بطل الموسم','🏆','بطل الموسم'),
('thousand_wins','ألف انتصار','⚔️','محارب الألف'),
('arena_legend','أسطورة الحلبة','👑','أسطورة الحلبة'),
('star_hunter','صياد النجوم','🌟','صياد النجوم'),
('invincible_castle','قلعة لا تُقهر','🏰','حامي القلعة'),
('lightning_speed','سرعة البرق','⚡','البرق'),
('chest_king','ملك السحب','🎁','ملك السحب'),
('clan_leader','قائد الكلان','🎖️','قائد الكلان')
on conflict (id) do update set name=excluded.name, icon=excluded.icon, title=excluded.title;

create table if not exists public.player_badges (
  user_id uuid not null references auth.users(id) on delete cascade,
  badge_id text not null references public.badges(id) on delete cascade,
  earned_at timestamptz not null default now(),
  primary key (user_id, badge_id)
);

alter table public.badges enable row level security;
alter table public.player_badges enable row level security;

drop policy if exists "badges_public_read" on public.badges;
create policy "badges_public_read"
on public.badges for select
using (true);

drop policy if exists "player_badges_public_read" on public.player_badges;
create policy "player_badges_public_read"
on public.player_badges for select
using (true);

-- Only the database function can grant badges. There is intentionally no
-- direct INSERT policy for normal users.
create or replace function public.admin_award_badge(
  p_user_id uuid,
  p_badge_id text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Only admins can award badges';
  end if;

  if not exists (select 1 from public.players where user_id = p_user_id) then
    raise exception 'Player not found';
  end if;

  if not exists (select 1 from public.badges where id = p_badge_id) then
    raise exception 'Badge not found';
  end if;

  insert into public.player_badges(user_id,badge_id)
  values(p_user_id,p_badge_id)
  on conflict (user_id,badge_id) do nothing;

  return jsonb_build_object('success',true,'user_id',p_user_id,'badge_id',p_badge_id);
end;
$$;

revoke all on function public.admin_award_badge(uuid,text) from public;
grant execute on function public.admin_award_badge(uuid,text) to authenticated;
