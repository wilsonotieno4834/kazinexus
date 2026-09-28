-- KaziNexus final remaining database integration
-- Audit trails, job alerts, partnerships, trust reports, featured jobs and analytics

-- 1. Job moderation audit trigger
create or replace function public.log_job_status_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.status is distinct from new.status and exists (select 1 from public.admin_users where user_id=auth.uid() and active=true) then
    insert into public.job_moderation_log(job_id, admin_user_id, old_status, new_status, note)
    values (new.id, auth.uid(), old.status, new.status, new.moderation_note);
    new.reviewed_at = now();
    new.reviewed_by = auth.uid();
  end if;
  return new;
end;
$$;

drop trigger if exists jobs_status_audit on public.jobs;
create trigger jobs_status_audit
before update on public.jobs
for each row execute function public.log_job_status_change();

-- 2. Employer verification audit trigger
create or replace function public.log_employer_verification_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.verified is distinct from new.verified and exists (select 1 from public.admin_users where user_id=auth.uid() and active=true) then
    insert into public.employer_verification_log(employer_id, admin_user_id, old_status, new_status, note)
    values (new.id, auth.uid(), case when old.verified then 'verified' else 'unverified' end,
            case when new.verified then 'verified' else 'unverified' end, null);
    new.verification_status = case when new.verified then 'verified' else 'unverified' end;
    new.verified_at = case when new.verified then now() else null end;
    new.verified_by = case when new.verified then auth.uid() else null end;
  end if;
  return new;
end;
$$;

drop trigger if exists employers_verification_audit on public.employers;
create trigger employers_verification_audit
before update on public.employers
for each row execute function public.log_employer_verification_change();

-- 3. Job alerts
create table if not exists public.job_alerts (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  keyword text,
  location text,
  job_type text,
  category_id uuid references public.categories(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists job_alerts_email_idx on public.job_alerts(email);
create index if not exists job_alerts_active_idx on public.job_alerts(active);
alter table public.job_alerts enable row level security;
drop policy if exists "Anyone can create job alerts" on public.job_alerts;
create policy "Anyone can create job alerts" on public.job_alerts for insert to anon, authenticated with check (true);
drop policy if exists "Users can view their alerts" on public.job_alerts;
create policy "Users can view their alerts" on public.job_alerts for select to authenticated using (email = coalesce(auth.jwt()->>'email',''));
drop policy if exists "Users can manage their alerts" on public.job_alerts;
create policy "Users can manage their alerts" on public.job_alerts for update using (email = coalesce(auth.jwt()->>'email','')) with check (email = coalesce(auth.jwt()->>'email',''));
create trigger job_alerts_updated_at before update on public.job_alerts for each row execute function public.set_updated_at();

-- 4. Partnership/contact/scam reporting inbox
create table if not exists public.contact_messages (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  phone text,
  subject text,
  message text not null,
  status text not null default 'new' check(status in ('new','in_progress','resolved','spam')),
  created_at timestamptz not null default now()
);
alter table public.contact_messages enable row level security;
drop policy if exists "Public can send contact messages" on public.contact_messages for insert to anon, authenticated with check(true);
drop policy if exists "Admins manage contact messages" on public.contact_messages for all to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true)) with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

create table if not exists public.partnership_requests (
  id uuid primary key default gen_random_uuid(),
  organization_name text not null,
  contact_person text not null,
  email text not null,
  phone text,
  partnership_type text,
  message text not null,
  status text not null default 'new' check(status in ('new','contacted','approved','declined')),
  created_at timestamptz not null default now()
);
alter table public.partnership_requests enable row level security;
drop policy if exists "Public can send partnership requests" on public.partnership_requests for insert to anon, authenticated with check(true);
drop policy if exists "Admins manage partnership requests" on public.partnership_requests for all to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true)) with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

create table if not exists public.trust_reports (
  id uuid primary key default gen_random_uuid(),
  reporter_name text,
  reporter_email text,
  job_id uuid references public.jobs(id) on delete set null,
  employer_id uuid references public.employers(id) on delete set null,
  reason text not null,
  details text not null,
  status text not null default 'new' check(status in ('new','reviewing','resolved','dismissed')),
  created_at timestamptz not null default now()
);
alter table public.trust_reports enable row level security;
drop policy if exists "Public can submit trust reports" on public.trust_reports for insert to anon, authenticated with check(true);
drop policy if exists "Admins manage trust reports" on public.trust_reports for all to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true)) with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

-- 5. Featured jobs support
alter table public.jobs add column if not exists featured boolean not null default false;
create index if not exists jobs_featured_idx on public.jobs(featured) where featured=true;

-- 6. Basic employer analytics view
create or replace view public.employer_job_analytics with (security_invoker=true) as
select j.employer_id, j.id as job_id, j.title, j.status, j.created_at, j.deadline,
       count(a.id) as applications_count,
       count(a.id) filter (where a.status='shortlisted') as shortlisted_count,
       count(a.id) filter (where a.status='hired') as hired_count
from public.jobs j
left join public.applications a on a.job_id=j.id
group by j.employer_id,j.id,j.title,j.status,j.created_at,j.deadline;

-- 7. Admin-only analytics policy cannot be applied directly to a view; expose through underlying RLS and use only authenticated admin/employer UI.

-- 8. Prevent public access to draft/pending jobs is already enforced by jobs RLS.


revoke all on public.employer_job_analytics from anon, authenticated;
grant select on public.employer_job_analytics to authenticated;

-- 9. KaziNexus paid-service request pipeline (basic job posting remains free)
create table if not exists public.service_requests (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references auth.users(id) on delete cascade,
  service_type text not null check (service_type in ('cv_revamp','talent_matching','recruitment_support')),
  name text not null,
  phone text,
  email text,
  details text not null,
  status text not null default 'new' check (status in ('new','contacted','in_progress','completed','cancelled')),
  amount numeric(12,2) not null default 0,
  payment_status text not null default 'pending' check (payment_status in ('pending','paid','failed','cancelled')),
  created_at timestamptz not null default now()
);
alter table public.service_requests enable row level security;
drop policy if exists "Users create own service requests" on public.service_requests;
create policy "Users create own service requests" on public.service_requests for insert to authenticated with check (requester_id=auth.uid());
drop policy if exists "Users view own service requests" on public.service_requests;
create policy "Users view own service requests" on public.service_requests for select to authenticated using (requester_id=auth.uid());
drop policy if exists "Admins manage service requests" on public.service_requests;
create policy "Admins manage service requests" on public.service_requests for all to authenticated using (exists(select 1 from public.admin_users where user_id=auth.uid() and active=true)) with check (exists(select 1 from public.admin_users where user_id=auth.uid() and active=true));
create index if not exists service_requests_status_idx on public.service_requests(status);
create index if not exists service_requests_requester_idx on public.service_requests(requester_id);

-- 12. Growth: employer referrals and privacy-friendly site events
create table if not exists public.employer_referrals (
  id uuid primary key default gen_random_uuid(), referrer_name text not null, referrer_email text not null,
  employer_name text not null, employer_contact text, message text,
  status text not null default 'new' check(status in ('new','contacted','converted','closed')),
  created_at timestamptz not null default now()
);
alter table public.employer_referrals enable row level security;
drop policy if exists "Public can submit employer referrals" on public.employer_referrals;
create policy "Public can submit employer referrals" on public.employer_referrals for insert to anon, authenticated with check(true);
drop policy if exists "Admins manage employer referrals" on public.employer_referrals;
create policy "Admins manage employer referrals" on public.employer_referrals for all to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true)) with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

create table if not exists public.site_events (
  id uuid primary key default gen_random_uuid(), event_name text not null, path text, job_id uuid references public.jobs(id) on delete set null,
  referrer text, created_at timestamptz not null default now()
);
alter table public.site_events enable row level security;
drop policy if exists "Public can record site events" on public.site_events;
create policy "Public can record site events" on public.site_events for insert to anon, authenticated with check(length(event_name) <= 80);
drop policy if exists "Admins view site events" on public.site_events;
create policy "Admins view site events" on public.site_events for select to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));
create index if not exists site_events_name_created_idx on public.site_events(event_name,created_at);
create index if not exists site_events_job_idx on public.site_events(job_id);
