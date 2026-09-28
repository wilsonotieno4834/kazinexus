# KaziNexus — One Final Platform Package

This folder combines the KaziNexus public site and the Job Seeker, Employer, Admin, moderation, verification, application, safety, alerts, monetization and SEO modules into one project structure.

## Main routes
- `/` — public homepage
- `/jobs/` — live job search
- `/apply/` — application page
- `/jobseekers/auth.html` — job seeker signup/login
- `/jobseekers/dashboard.html` — job seeker dashboard
- `/employers/auth.html` — employer signup/login
- `/employers/dashboard.html` — employer dashboard
- `/employers/post-job.html` — employer job posting (submitted as pending)
- `/admin.html` — admin login
- `/admin-dashboard.html` — admin dashboard
- `/public-jobs.html` — public jobs module
- `/report.html` — safety reporting
- `/job-alerts.html` — job alerts
- `/monetization.html` — promotion/monetization module

## Database
`KaziNexus_MASTER_DATABASE.sql` contains the accumulated upgrade SQL. Run it in Supabase SQL Editor after the original KaziNexus base schema.

## Deployment
Deploy with Cloudflare Pages (static files / legacy Pages workflow). Do not deploy this package as a standalone Workers script. The expected public URL will be a pages.dev address. Supabase remains the backend.

## Secure open posting workflow
KaziNexus allows anyone to submit/share legitimate opportunities for free. Posting privilege is determined server-side. Admins, verified employers, approved HR/recruiters and approved partners publish directly; regular/new/unverified posters enter the admin approval queue. The client cannot grant itself a privileged role. Apply `KaziNexus_OPEN_POSTING_SECURE.sql` in Supabase before using `/post-opportunity.html`.
