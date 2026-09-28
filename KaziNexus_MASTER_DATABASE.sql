-- KaziNexus master database upgrade.
-- Run after the base schema. Safe to re-run where practical.
-- ===== kazinexus_admin_security.sql =====
-- KaziNexus Admin Security + Employer Verification
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'admin',
  active boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

drop policy if exists "Admins can view own admin record" on public.admin_users;
create policy "Admins can view own admin record"
on public.admin_users for select to authenticated
using (user_id = auth.uid());

alter table public.employers add column if not exists verified boolean not null default false;

drop policy if exists "Admins manage all jobs" on public.jobs;
create policy "Admins manage all jobs" on public.jobs for all to authenticated
using (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true))
with check (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true));

drop policy if exists "Admins manage all employers" on public.employers;
create policy "Admins manage all employers" on public.employers for all to authenticated
using (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true))
with check (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true));

drop policy if exists "Admins manage all applications" on public.applications;
create policy "Admins manage all applications" on public.applications for all to authenticated
using (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true))
with check (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true));

-- After creating/logging into your admin account, add its UUID:
-- insert into public.admin_users (user_id) values ('YOUR-USER-UUID');
-- ===== kazinexus_employer_verification.sql =====
-- KaziNexus Employer Verification workflow
-- Adds verification metadata and an audit trail.

alter table public.employers
  add column if not exists verification_status text not null default 'unverified'
    check (verification_status in ('unverified','pending','verified','rejected')),
  add column if not exists verified_at timestamptz,
  add column if not exists verified_by uuid references auth.users(id) on delete set null;

create table if not exists public.employer_verification_log (
  id uuid primary key default gen_random_uuid(),
  employer_id uuid not null references public.employers(id) on delete cascade,
  admin_user_id uuid not null references auth.users(id) on delete restrict,
  old_status text,
  new_status text not null,
  note text,
  created_at timestamptz not null default now()
);

create index if not exists employer_verification_log_employer_idx
  on public.employer_verification_log(employer_id, created_at desc);

alter table public.employer_verification_log enable row level security;

drop policy if exists "Admins manage verification logs" on public.employer_verification_log;
create policy "Admins manage verification logs"
on public.employer_verification_log
for all to authenticated
using (exists (
  select 1 from public.admin_users
  where user_id = auth.uid() and active = true
))
with check (exists (
  select 1 from public.admin_users
  where user_id = auth.uid() and active = true
));

-- Keep the existing simple verified flag in sync with the workflow status.
update public.employers
set verification_status = case when verified then 'verified' else 'unverified' end
where verification_status = 'unverified';
-- ===== kazinexus_platform_upgrade.sql =====
-- KaziNexus remaining platform upgrade
-- Public jobs, reports, alerts, monetization and supporting security.

-- 1. Public job moderation fields
alter table public.jobs
  add column if not exists featured boolean not null default false,
  add column if not exists featured_until timestamptz,
  add column if not exists views_count integer not null default 0;

-- 2. Reports / safety
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references auth.users(id) on delete set null,
  job_id uuid references public.jobs(id) on delete cascade,
  employer_id uuid references public.employers(id) on delete cascade,
  reason text not null,
  details text,
  status text not null default 'open'
    check (status in ('open','reviewing','resolved','dismissed')),
  admin_note text,
  reviewed_by uuid references auth.users(id) on delete set null,
  reviewed_at timestamptz,
  created_at timestamptz not null default now(),
  check (job_id is not null or employer_id is not null)
);

create index if not exists reports_status_idx on public.reports(status);
create index if not exists reports_job_idx on public.reports(job_id);
create index if not exists reports_employer_idx on public.reports(employer_id);

alter table public.reports enable row level security;

drop policy if exists "Users submit reports" on public.reports;
create policy "Users submit reports"
on public.reports for insert to authenticated
with check (reporter_id = auth.uid());

drop policy if exists "Users view own reports" on public.reports;
create policy "Users view own reports"
on public.reports for select to authenticated
using (reporter_id = auth.uid());

drop policy if exists "Admins manage reports" on public.reports;
create policy "Admins manage reports"
on public.reports for all to authenticated
using (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true))
with check (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true));

-- 3. Job alerts
create table if not exists public.job_alerts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  keyword text,
  category_id uuid references public.categories(id) on delete set null,
  county text,
  job_type text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists job_alerts_user_idx on public.job_alerts(user_id);
create index if not exists job_alerts_active_idx on public.job_alerts(active);

alter table public.job_alerts enable row level security;

drop policy if exists "Users manage own job alerts" on public.job_alerts;
create policy "Users manage own job alerts"
on public.job_alerts for all to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

-- 4. Monetization: optional paid promotion records.
-- Basic job posting remains free.
create table if not exists public.job_promotions (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  employer_id uuid not null references public.employers(id) on delete cascade,
  promotion_type text not null
    check (promotion_type in ('featured','urgent','homepage')),
  starts_at timestamptz not null default now(),
  ends_at timestamptz not null,
  payment_status text not null default 'pending'
    check (payment_status in ('pending','paid','failed','cancelled')),
  amount numeric(12,2) not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists job_promotions_job_idx on public.job_promotions(job_id);
create index if not exists job_promotions_employer_idx on public.job_promotions(employer_id);

alter table public.job_promotions enable row level security;

drop policy if exists "Employers manage own promotions" on public.job_promotions;
create policy "Employers manage own promotions"
on public.job_promotions for all to authenticated
using (employer_id = auth.uid())
with check (employer_id = auth.uid());

drop policy if exists "Admins manage promotions" on public.job_promotions;
create policy "Admins manage promotions"
on public.job_promotions for all to authenticated
using (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true))
with check (exists (select 1 from public.admin_users where user_id=auth.uid() and active=true));

-- 5. Updated-at trigger for alerts
 drop trigger if exists job_alerts_updated_at on public.job_alerts;
create trigger job_alerts_updated_at
before update on public.job_alerts
for each row execute function public.set_updated_at();

-- 6. Public view for active jobs. This avoids exposing draft/pending/closed jobs.
create or replace view public.public_active_jobs as
select
  j.id, j.title, j.company, j.location, j.job_type, j.salary,
  j.category_id, c.name as category_name, j.description,
  j.responsibilities, j.qualifications, j.application_email,
  j.application_link, j.contact_person, j.deadline, j.created_at,
  j.featured, j.featured_until, j.views_count,
  e.verified as employer_verified
from public.jobs j
left join public.categories c on c.id = j.category_id
left join public.employers e on e.id = j.employer_id
where j.status = 'active'
  and j.deadline >= current_date;

-- NOTE: Supabase may require explicit grants for the anon role depending on project defaults.
-- The existing jobs RLS remains the primary public access control.
-- ===== kazinexus_job_seeker_trigger.sql =====
create or replace function public.handle_new_job_seeker()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.raw_user_meta_data->>'role','') = 'job_seeker' then
    insert into public.job_seekers (id, full_name, phone, location, headline, bio, skills)
    values (
      new.id,
      coalesce(nullif(new.raw_user_meta_data->>'full_name',''), 'Job Seeker'),
      nullif(new.raw_user_meta_data->>'phone',''),
      nullif(new.raw_user_meta_data->>'location',''),
      nullif(new.raw_user_meta_data->>'headline',''),
      nullif(new.raw_user_meta_data->>'bio',''),
      nullif(new.raw_user_meta_data->>'skills','')
    )
    on conflict (id) do update
    set full_name = excluded.full_name,
        phone = excluded.phone,
        location = excluded.location,
        headline = excluded.headline,
        bio = excluded.bio,
        skills = excluded.skills,
        updated_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_job_seeker on auth.users;
create trigger on_auth_user_created_job_seeker
after insert on auth.users
for each row execute function public.handle_new_job_seeker();
-- ===== kazinexus_job_seeker_profile_update.sql =====
-- KaziNexus Job Seeker Profile: ensure trigger copies all supported profile fields.
create or replace function public.handle_new_job_seeker()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(new.raw_user_meta_data->>'role','') = 'job_seeker' then
    insert into public.job_seekers (
      id, full_name, phone, location, headline, bio, skills, cv_url
    ) values (
      new.id,
      coalesce(nullif(new.raw_user_meta_data->>'full_name',''), 'Job Seeker'),
      nullif(new.raw_user_meta_data->>'phone',''),
      nullif(new.raw_user_meta_data->>'location',''),
      nullif(new.raw_user_meta_data->>'headline',''),
      nullif(new.raw_user_meta_data->>'bio',''),
      nullif(new.raw_user_meta_data->>'skills',''),
      nullif(new.raw_user_meta_data->>'cv_url','')
    )
    on conflict (id) do update set
      full_name = excluded.full_name,
      phone = excluded.phone,
      location = excluded.location,
      headline = excluded.headline,
      bio = excluded.bio,
      skills = excluded.skills,
      cv_url = excluded.cv_url,
      updated_at = now();
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created_job_seeker on auth.users;
create trigger on_auth_user_created_job_seeker
after insert on auth.users
for each row execute function public.handle_new_job_seeker();
