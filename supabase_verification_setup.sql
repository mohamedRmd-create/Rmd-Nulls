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
