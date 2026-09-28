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
