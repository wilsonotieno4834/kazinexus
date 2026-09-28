

-- KaziNexus Platform Analytics (admin-only)
create table if not exists public.job_events (
  id uuid primary key default gen_random_uuid(),
  job_id uuid references public.jobs(id) on delete cascade,
  event_type text not null check(event_type in ('view','share','apply_click','whatsapp_click','external_click')),
  source text,
  session_id text,
  created_at timestamptz not null default now()
);
create index if not exists job_events_job_idx on public.job_events(job_id);
create index if not exists job_events_type_idx on public.job_events(event_type);
create index if not exists job_events_created_idx on public.job_events(created_at desc);
alter table public.job_events enable row level security;
drop policy if exists "Public can record job events" on public.job_events;
create policy "Public can record job events" on public.job_events for insert to anon, authenticated with check (job_id is not null);
drop policy if exists "Admins can read job events" on public.job_events;
create policy "Admins can read job events" on public.job_events for select to authenticated using(exists(select 1 from public.admin_users a where a.user_id=auth.uid() and a.active=true));

-- Generic admin-safe summary view
create or replace view public.admin_job_event_summary with (security_invoker=true) as
select j.id as job_id,j.title,
 count(e.id) filter(where e.event_type='view') as views,
 count(e.id) filter(where e.event_type='share') as shares,
 count(e.id) filter(where e.event_type='apply_click') as apply_clicks,
 count(e.id) filter(where e.event_type='whatsapp_click') as whatsapp_clicks
from public.jobs j left join public.job_events e on e.job_id=j.id
group by j.id,j.title;
revoke all on public.admin_job_event_summary from anon;
grant select on public.admin_job_event_summary to authenticated;
