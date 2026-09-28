-- KaziNexus final operations, automation and reporting layer.
-- Safe to re-run. Run after KaziNexus_MASTER_DATABASE.sql and KaziNexus_ANALYTICS.sql.

-- Job expiry: keeps old vacancies from remaining active after deadline.
create or replace function public.close_expired_jobs()
returns integer
language plpgsql
security definer
set search_path=public
as $$
declare n integer;
begin
  update public.jobs
  set status='closed'
  where status='active'
    and deadline is not null
    and deadline < current_date;
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Notification queue for job alerts and operational emails.
-- A trusted server/Edge Function should consume this queue; no service key belongs in browser code.
create table if not exists public.notification_queue (
  id uuid primary key default gen_random_uuid(),
  recipient_email text not null,
  notification_type text not null check(notification_type in ('job_alert','application_update','service_request','admin_digest')),
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'queued' check(status in ('queued','processing','sent','failed','cancelled')),
  attempts integer not null default 0,
  last_error text,
  scheduled_for timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notification_queue_ready_idx on public.notification_queue(status,scheduled_for);
alter table public.notification_queue enable row level security;
drop policy if exists "Admins manage notification queue" on public.notification_queue;
create policy "Admins manage notification queue" on public.notification_queue for all to authenticated
using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true))
with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

-- Admin KPI views. Security-invoker + underlying RLS prevents ordinary users from reading protected data.
create or replace view public.admin_platform_kpis with (security_invoker=true) as
select
 (select count(*) from public.jobs) as total_jobs,
 (select count(*) from public.jobs where status='active') as active_jobs,
 (select count(*) from public.jobs where status='pending') as pending_jobs,
 (select count(*) from public.employers) as total_employers,
 (select count(*) from public.employers where verified=true) as verified_employers,
 (select count(*) from public.applications) as total_applications,
 (select count(*) from public.job_events where event_type='view') as total_views,
 (select count(*) from public.job_events where event_type='share') as total_shares,
 (select count(*) from public.job_alerts where active=true) as active_job_alerts,
 (select count(*) from public.notification_queue where status='queued') as queued_notifications;
revoke all on public.admin_platform_kpis from anon;
grant select on public.admin_platform_kpis to authenticated;

create or replace view public.admin_top_jobs with (security_invoker=true) as
select j.id,j.title,j.company,j.location,j.status,
 count(e.id) filter(where e.event_type='view') as views,
 count(e.id) filter(where e.event_type='share') as shares,
 count(a.id) as applications
from public.jobs j
left join public.job_events e on e.job_id=j.id
left join public.applications a on a.job_id=j.id
group by j.id,j.title,j.company,j.location,j.status
order by views desc, applications desc;
revoke all on public.admin_top_jobs from anon;
grant select on public.admin_top_jobs to authenticated;

-- Daily search/activity aggregate storage without storing unnecessary personal identifiers.
create table if not exists public.platform_daily_metrics (
  metric_date date primary key,
  job_views integer not null default 0,
  job_shares integer not null default 0,
  apply_clicks integer not null default 0,
  applications integer not null default 0,
  new_jobs integer not null default 0,
  new_employers integer not null default 0,
  new_job_seekers integer not null default 0,
  created_at timestamptz not null default now()
);
alter table public.platform_daily_metrics enable row level security;
drop policy if exists "Admins manage daily metrics" on public.platform_daily_metrics;
create policy "Admins manage daily metrics" on public.platform_daily_metrics for all to authenticated
using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true))
with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

create or replace function public.refresh_daily_metrics(p_date date default current_date)
returns void
language plpgsql
security definer
set search_path=public
as $$
begin
  insert into public.platform_daily_metrics(metric_date,job_views,job_shares,apply_clicks,applications,new_jobs,new_employers,new_job_seekers)
  values(
    p_date,
    (select count(*) from public.job_events where event_type='view' and created_at::date=p_date),
    (select count(*) from public.job_events where event_type='share' and created_at::date=p_date),
    (select count(*) from public.job_events where event_type='apply_click' and created_at::date=p_date),
    (select count(*) from public.applications where created_at::date=p_date),
    (select count(*) from public.jobs where created_at::date=p_date),
    (select count(*) from public.employers where created_at::date=p_date),
    (select count(*) from auth.users where created_at::date=p_date)
  )
on conflict(metric_date) do update set
 job_views=excluded.job_views,job_shares=excluded.job_shares,apply_clicks=excluded.apply_clicks,
 applications=excluded.applications,new_jobs=excluded.new_jobs,new_employers=excluded.new_employers,
 new_job_seekers=excluded.new_job_seekers;
end;
$$;

-- Operational audit record for sensitive admin actions.
create table if not exists public.admin_activity_log (
 id uuid primary key default gen_random_uuid(),
 admin_user_id uuid references auth.users(id) on delete set null,
 action text not null,
 entity_type text,
 entity_id uuid,
 details jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now()
);
create index if not exists admin_activity_created_idx on public.admin_activity_log(created_at desc);
alter table public.admin_activity_log enable row level security;
drop policy if exists "Admins manage activity log" on public.admin_activity_log;
create policy "Admins manage activity log" on public.admin_activity_log for all to authenticated
using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true))
with check(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

-- Helpful indexes for growth-scale queries.
create index if not exists jobs_status_deadline_idx on public.jobs(status,deadline);
create index if not exists jobs_created_idx on public.jobs(created_at desc);
create index if not exists applications_created_idx on public.applications(created_at desc);
create index if not exists employers_created_idx on public.employers(created_at desc);
