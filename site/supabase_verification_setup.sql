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



-- 9) Admin-only test players.
alter table public.players add column if not exists player_tag text;
alter table public.players add column if not exists social_username text;
alter table public.players add column if not exists is_test_player boolean default false;

create or replace function public.admin_create_test_player(
  p_username text, p_trophies integer default 0, p_wins integer default 0,
  p_player_tag text default null, p_social_username text default null,
  p_best_trophies integer default 0
) returns uuid language plpgsql security definer set search_path = public, auth as $$
declare v_uid uuid := gen_random_uuid(); v_email text := 'test_' || replace(v_uid::text,'-','') || '@rmd-null.local';
begin
  if not public.is_admin() then raise exception 'Only an admin can create test players'; end if;
  if nullif(trim(p_username),'') is null then raise exception 'Player name is required'; end if;
  if p_trophies < 0 or p_wins < 0 or p_best_trophies < 0 then raise exception 'Numeric values cannot be negative'; end if;
  insert into auth.users (id,instance_id,aud,role,email,encrypted_password,email_confirmed_at,raw_app_meta_data,raw_user_meta_data,created_at,updated_at)
  values (v_uid,'00000000-0000-0000-0000-000000000000','authenticated','authenticated',v_email,null,now(),jsonb_build_object('role','test_player','test_player',true),jsonb_build_object('test_player',true),now(),now());
  insert into public.players (user_id,username,trophies,wins,best_trophies,verified,verified_at,player_tag,social_username,is_test_player)
  values (v_uid,trim(p_username),p_trophies,p_wins,greatest(p_best_trophies,p_trophies),true,now(),nullif(trim(p_player_tag),''),nullif(trim(p_social_username),''),true);
  return v_uid;
end; $$;
revoke all on function public.admin_create_test_player(text,integer,integer,text,text,integer) from public;
grant execute on function public.admin_create_test_player(text,integer,integer,text,text,integer) to authenticated;


-- 10) Current 13-day season system.
create table if not exists public.season_settings (
  id integer primary key default 1 check (id = 1),
  season_name text not null default 'الموسم الحالي',
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null default (now() + interval '13 days'),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

insert into public.season_settings (id, season_name, starts_at, ends_at)
values (1, 'الموسم الحالي', now(), now() + interval '13 days')
on conflict (id) do nothing;

create table if not exists public.season_player_stats (
  season_id integer not null default 1 references public.season_settings(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  trophies_gained integer not null default 0 check (trophies_gained >= 0),
  rank_gained integer not null default 0 check (rank_gained >= 0),
  achievements text[] not null default '{}',
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id),
  primary key (season_id, user_id)
);

alter table public.season_settings enable row level security;
alter table public.season_player_stats enable row level security;

drop policy if exists "season_settings_public_read" on public.season_settings;
create policy "season_settings_public_read"
on public.season_settings for select to anon, authenticated using (true);

drop policy if exists "season_settings_admin_write" on public.season_settings;
create policy "season_settings_admin_write"
on public.season_settings for update to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "season_stats_public_read" on public.season_player_stats;
create policy "season_stats_public_read"
on public.season_player_stats for select to anon, authenticated using (true);

drop policy if exists "season_stats_admin_insert" on public.season_player_stats;
create policy "season_stats_admin_insert"
on public.season_player_stats for insert to authenticated
with check (public.is_admin());

drop policy if exists "season_stats_admin_update" on public.season_player_stats;
create policy "season_stats_admin_update"
on public.season_player_stats for update to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists "season_stats_admin_delete" on public.season_player_stats;
create policy "season_stats_admin_delete"
on public.season_player_stats for delete to authenticated
using (public.is_admin());

-- Admin-only player deletion.
-- Removes site data first, then the player row. The Auth account is intentionally kept.
-- The dynamic FK cleanup below also handles older/legacy site tables that may reference
-- public.players directly, which prevents old unverified players from getting stuck.
create or replace function public.admin_delete_player(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth, pg_catalog
as $$
declare
  fk record;
  v_count bigint;
  v_exists boolean;
begin
  if not public.is_admin() then
    raise exception 'Only an admin can delete players';
  end if;
  if p_user_id is null then
    raise exception 'Player user id is required';
  end if;

  select exists(select 1 from public.players where user_id = p_user_id) into v_exists;
  if not v_exists then
    raise exception 'Player not found';
  end if;

  -- Known Rmd Null tables.
  delete from public.player_badges where user_id = p_user_id;
  delete from public.verification_requests where user_id = p_user_id;
  delete from public.season_player_stats where user_id = p_user_id;

  -- Legacy compatibility: remove rows from public tables that have a single-column
  -- foreign key directly referencing players.user_id. This is intentionally limited
  -- to public schema and to the players.user_id key; it cannot touch auth/storage.
  for fk in
    select
      n.nspname as schema_name,
      c.relname as table_name,
      a.attname as column_name
    from pg_constraint con
    join pg_class c on c.oid = con.conrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_class rc on rc.oid = con.confrelid
    join pg_namespace rn on rn.oid = rc.relnamespace
    join unnest(con.conkey) with ordinality ck(attnum, ord) on true
    join unnest(con.confkey) with ordinality rck(attnum, ord) on rck.ord = ck.ord
    join pg_attribute a on a.attrelid = c.oid and a.attnum = ck.attnum
    join pg_attribute ra on ra.attrelid = rc.oid and ra.attnum = rck.attnum
    where con.contype = 'f'
      and n.nspname = 'public'
      and rn.nspname = 'public'
      and rc.relname = 'players'
      and ra.attname = 'user_id'
      and array_length(con.conkey,1) = 1
      and not (c.relname in ('player_badges','verification_requests','season_player_stats'))
  loop
    execute format('delete from %I.%I where %I = $1', fk.schema_name, fk.table_name, fk.column_name)
      using p_user_id;
  end loop;

  delete from public.players where user_id = p_user_id;
  get diagnostics v_count = row_count;
  if v_count <> 1 then
    raise exception 'Player could not be deleted';
  end if;

  return true;
end;
$$;
revoke all on function public.admin_delete_player(uuid) from public;
grant execute on function public.admin_delete_player(uuid) to authenticated;

-- Admin RPC for editing a player's current-season statistics.
create or replace function public.admin_upsert_season_player(
  p_user_id uuid,
  p_trophies_gained integer default 0,
  p_rank_gained integer default 0,
  p_achievements text[] default '{}'
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can edit season statistics'; end if;
  if p_user_id is null then raise exception 'Player user id is required'; end if;
  if p_trophies_gained < 0 or p_rank_gained < 0 then raise exception 'Season values cannot be negative'; end if;
  insert into public.season_player_stats(season_id,user_id,trophies_gained,rank_gained,achievements,updated_at,updated_by)
  values(1,p_user_id,p_trophies_gained,p_rank_gained,coalesce(p_achievements,'{}'),now(),auth.uid())
  on conflict (season_id,user_id) do update set
    trophies_gained=excluded.trophies_gained,
    rank_gained=excluded.rank_gained,
    achievements=excluded.achievements,
    updated_at=now(),
    updated_by=auth.uid();
  return true;
end;
$$;
revoke all on function public.admin_upsert_season_player(uuid,integer,integer,text[]) from public;
grant execute on function public.admin_upsert_season_player(uuid,integer,integer,text[]) to authenticated;

-- Admin RPC for setting the current season dates/name.
create or replace function public.admin_update_season(
  p_season_name text,
  p_starts_at timestamptz,
  p_ends_at timestamptz
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can edit the season'; end if;
  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'Invalid season dates';
  end if;
  update public.season_settings
  set season_name=coalesce(nullif(trim(p_season_name),''),'الموسم الحالي'),
      starts_at=p_starts_at, ends_at=p_ends_at, updated_at=now(), updated_by=auth.uid()
  where id=1;
  return true;
end;
$$;
revoke all on function public.admin_update_season(text,timestamptz,timestamptz) from public;
grant execute on function public.admin_update_season(text,timestamptz,timestamptz) to authenticated;


-- 11) Manual player ranks, profile appearance, and duplicate-proof badge awards.
alter table public.players add column if not exists rank text not null default 'bronze';
alter table public.players add column if not exists avatar_key text default 'starter';
alter table public.players add column if not exists frame_key text default 'classic';

update public.players set rank='bronze' where rank is null or trim(rank)='';
update public.players set avatar_key='starter' where avatar_key is null or trim(avatar_key)='';
update public.players set frame_key='classic' where frame_key is null or trim(frame_key)='';
-- Migrate the previous cosmetic keys to the new illustrated assets.
update public.players set avatar_key=case avatar_key
  when 'tiger' then 'pirate_flag'
  when 'robot' then 'royal_chicken'
  when 'skull' then 'pirate_skull'
  when 'star' then 'ninja'
  when 'crown' then 'tea_knight'
  else avatar_key end
where avatar_key in ('tiger','robot','skull','star','crown');

alter table public.players drop constraint if exists players_rank_check;
alter table public.players add constraint players_rank_check check (rank in ('bronze','silver','gold','diamond','masters'));

-- Remove accidental duplicate awards, keeping the earliest earned row.
DO $$
BEGIN
  IF to_regclass('public.player_badges') IS NOT NULL THEN
    DELETE FROM public.player_badges a
    USING public.player_badges b
    WHERE a.ctid < b.ctid
      AND a.user_id = b.user_id
      AND a.badge_id = b.badge_id;
  END IF;
END $$;

create unique index if not exists player_badges_user_badge_unique
on public.player_badges(user_id,badge_id);

-- Recreate the admin award RPC so repeated clicks cannot duplicate a badge/title.
create or replace function public.admin_award_badge(
  p_user_id uuid,
  p_badge_id text
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can award badges'; end if;
  if p_user_id is null or nullif(trim(p_badge_id),'') is null then raise exception 'Player and badge are required'; end if;
  if not exists(select 1 from public.players where user_id=p_user_id) then raise exception 'Player not found'; end if;
  if not exists(select 1 from public.badges where id=p_badge_id) then raise exception 'Badge not found'; end if;
  insert into public.player_badges(user_id,badge_id,earned_at)
  values(p_user_id,p_badge_id,now())
  on conflict (user_id,badge_id) do nothing;
  return true;
end;
$$;
revoke all on function public.admin_award_badge(uuid,text) from public;
grant execute on function public.admin_award_badge(uuid,text) to authenticated;

-- Admin-only badge removal. This removes one specific badge from one player.
create or replace function public.admin_remove_badge(
  p_user_id uuid,
  p_badge_id text
) returns boolean
language plpgsql security definer set search_path = public
as $$
declare v_deleted integer;
begin
  if not public.is_admin() then raise exception 'Only an admin can remove badges'; end if;
  if p_user_id is null or nullif(trim(p_badge_id),'') is null then raise exception 'Player and badge are required'; end if;
  delete from public.player_badges where user_id=p_user_id and badge_id=p_badge_id;
  get diagnostics v_deleted = row_count;
  if v_deleted = 0 then raise exception 'Badge is not assigned to this player'; end if;

  -- If the removed badge was the only unlock for a cosmetic, return that cosmetic
  -- to the safe defaults so the player is not left equipped with a locked item.
  if p_badge_id in ('arena_legend','clan_leader') and not exists (
    select 1 from public.player_badges pb
    where pb.user_id=p_user_id and pb.badge_id in ('arena_legend','clan_leader')
  ) then
    update public.players
    set avatar_key=case when avatar_key='pirate_flag' then 'starter' else avatar_key end,
        frame_key=case when frame_key='diamond' then 'classic' else frame_key end
    where user_id=p_user_id;
  end if;
  if p_badge_id='lightning_speed' then
    update public.players
    set avatar_key=case when avatar_key='tea_knight' then 'starter' else avatar_key end,
        frame_key=case when frame_key='gold' then 'classic' else frame_key end
    where user_id=p_user_id;
  end if;
  if p_badge_id='season_champion' then
    update public.players set frame_key=case when frame_key='silver' then 'classic' else frame_key end where user_id=p_user_id;
  end if;
  if p_badge_id='star_hunter' then
    update public.players set frame_key=case when frame_key='bronze' then 'classic' else frame_key end where user_id=p_user_id;
  end if;
  return true;
end;
$$;
revoke all on function public.admin_remove_badge(uuid,text) from public;
grant execute on function public.admin_remove_badge(uuid,text) to authenticated;

-- Admin-only manual rank change.
create or replace function public.admin_update_player_rank(
  p_user_id uuid,
  p_rank text
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can change player rank'; end if;
  if p_user_id is null then raise exception 'Player user id is required'; end if;
  if p_rank not in ('bronze','silver','gold','diamond','masters') then raise exception 'Invalid rank'; end if;
  update public.players set rank=p_rank where user_id=p_user_id;
  if not found then raise exception 'Player not found'; end if;
  return true;
end;
$$;
revoke all on function public.admin_update_player_rank(uuid,text) from public;
grant execute on function public.admin_update_player_rank(uuid,text) to authenticated;

-- Users may change only their own cosmetic appearance. This does not grant them
-- permission to change verification, rank, trophies, wins, or any other player data.
create or replace function public.set_player_appearance(
  p_avatar_key text,
  p_frame_key text
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_avatar_key not in ('starter','pirate_flag','royal_chicken','tea_knight','pirate_skull','ninja') then raise exception 'Invalid avatar'; end if;
  if p_frame_key not in ('classic','bronze','silver','gold','diamond','masters') then raise exception 'Invalid frame'; end if;

  -- Locked cosmetics are enforced server-side as well as in the UI.
  if p_avatar_key <> 'starter' and not exists (
    select 1 from public.player_badges pb
    where pb.user_id=auth.uid()
      and pb.badge_id = case p_avatar_key
        when 'pirate_flag' then 'arena_legend'
        when 'royal_chicken' then 'clan_leader'
        when 'tea_knight' then 'lightning_speed'
        when 'pirate_skull' then '__locked__'
        when 'ninja' then '__locked__'
      end
  ) then raise exception 'This avatar is locked until its badge is earned'; end if;

  if p_frame_key <> 'classic' and (
    (p_frame_key='bronze' and not exists (select 1 from public.player_badges pb where pb.user_id=auth.uid() and pb.badge_id='star_hunter'))
    or (p_frame_key='silver' and not exists (select 1 from public.player_badges pb where pb.user_id=auth.uid() and pb.badge_id='season_champion'))
    or (p_frame_key='gold' and not exists (select 1 from public.player_badges pb where pb.user_id=auth.uid() and pb.badge_id='lightning_speed'))
    or (p_frame_key='diamond' and not exists (select 1 from public.player_badges pb where pb.user_id=auth.uid() and pb.badge_id in ('arena_legend','clan_leader')))
    or (p_frame_key='masters')
  ) then raise exception 'This frame is locked until its badge is earned'; end if;

  update public.players
  set avatar_key=p_avatar_key, frame_key=p_frame_key
  where user_id=auth.uid();
  if not found then raise exception 'Player not found'; end if;
  return true;
end;
$$;
revoke all on function public.set_player_appearance(text,text) from public;
grant execute on function public.set_player_appearance(text,text) to authenticated;


-- 15) Clans: admin-managed public ranking data.
create table if not exists public.clans (
  id bigint generated by default as identity primary key,
  name text not null,
  tag text not null unique,
  total_trophies bigint not null default 0 check (total_trophies >= 0),
  member_count integer not null default 0 check (member_count >= 0),
  world_rank integer not null check (world_rank > 0),
  logo_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.clans enable row level security;

drop policy if exists "clans_public_select" on public.clans;
create policy "clans_public_select"
on public.clans for select
to anon, authenticated
using (true);

drop policy if exists "clans_admin_insert" on public.clans;
create policy "clans_admin_insert"
on public.clans for insert to authenticated
with check (public.is_admin());

drop policy if exists "clans_admin_update" on public.clans;
create policy "clans_admin_update"
on public.clans for update to authenticated
using (public.is_admin())
with check (public.is_admin());

drop policy if exists "clans_admin_delete" on public.clans;
create policy "clans_admin_delete"
on public.clans for delete to authenticated
using (public.is_admin());

create index if not exists clans_world_rank_idx on public.clans(world_rank);
create index if not exists clans_name_lower_idx on public.clans(lower(name));


-- Admin-only manual player data update. Used by the Admin Dashboard player settings panel.
create or replace function public.admin_update_player_data(
  p_user_id uuid,
  p_username text,
  p_trophies bigint,
  p_wins bigint,
  p_best_trophies bigint,
  p_player_tag text,
  p_social_username text,
  p_clan text,
  p_rank text
) returns boolean
language plpgsql security definer set search_path = public
as $$
begin
  if not public.is_admin() then raise exception 'Only an admin can update player data'; end if;
  if p_user_id is null then raise exception 'Player user id is required'; end if;
  if nullif(trim(coalesce(p_username,'')),'') is null then raise exception 'Player username is required'; end if;
  if coalesce(p_trophies,0) < 0 or coalesce(p_wins,0) < 0 or coalesce(p_best_trophies,0) < 0 then raise exception 'Player statistics cannot be negative'; end if;
  if p_rank not in ('bronze','silver','gold','diamond','masters') then raise exception 'Invalid rank'; end if;
  update public.players
  set username=trim(p_username),
      trophies=coalesce(p_trophies,0),
      wins=coalesce(p_wins,0),
      best_trophies=coalesce(p_best_trophies,0),
      player_tag=nullif(trim(coalesce(p_player_tag,'')),''),
      social_username=nullif(trim(coalesce(p_social_username,'')),''),
      clan=nullif(trim(coalesce(p_clan,'')),''),
      rank=p_rank,
      last_verified_at=now()
  where user_id=p_user_id;
  if not found then raise exception 'Player not found'; end if;
  return true;
end;
$$;
revoke all on function public.admin_update_player_data(uuid,text,bigint,bigint,bigint,text,text,text,text) from public;
grant execute on function public.admin_update_player_data(uuid,text,bigint,bigint,bigint,text,text,text,text) to authenticated;


-- ============================================================
-- 17) Player information updates from two screenshots + OCR.
-- Safe to run repeatedly: only adds missing columns/indexes/policies.
-- ============================================================
alter table public.verification_requests add column if not exists request_type text not null default 'verification';
alter table public.verification_requests add column if not exists image_path_2 text;
alter table public.verification_requests add column if not exists current_rank bigint;
alter table public.verification_requests add column if not exists ocr_extracted_json jsonb;
alter table public.verification_requests add column if not exists auto_decision text;
alter table public.verification_requests add column if not exists auto_decision_reason text;

alter table public.players add column if not exists current_rank bigint;
alter table public.players add column if not exists last_verified_at timestamptz;

create index if not exists verification_requests_request_type_idx on public.verification_requests(request_type);
create index if not exists verification_requests_auto_decision_idx on public.verification_requests(auto_decision);

-- Keep the existing verification RLS. This additional insert policy is intentionally
-- the same ownership rule, but permits the new request_type without exposing admin fields.
drop policy if exists "verification_requests_insert_own_data_update" on public.verification_requests;
create policy "verification_requests_insert_own_data_update"
on public.verification_requests for insert to authenticated
with check (auth.uid() = user_id and status = 'pending' and request_type = 'data_update');

-- The existing select/update policies remain in force. The Edge Function uses the
-- service_role key server-side, so it can safely write OCR results and approved data.
