-- =====================================================================
-- Absogrow AI - Business Acquisition System
-- Migration 0002: roles, grants and row-level security
--
-- Three kinds of caller:
--   anon                 - no access to anything.
--   authenticated        - a signed-in person. Sees data only if listed in
--                          staff_members. The only caller that can approve.
--   absogrow_automation  - the role n8n connects as. Can research, score,
--                          draft and log, but has NO write access to
--                          approvals, staff, or the audit trail, so an
--                          automation can never approve its own message.
--
-- The Supabase service_role key bypasses RLS entirely. Do not give it to
-- n8n; use absogrow_automation instead.
-- =====================================================================

begin;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'absogrow_automation') then
    -- Created without a password. Enable login and set the password by hand
    -- (ALTER ROLE ... LOGIN PASSWORD ...) so the secret never sits in a file.
    create role absogrow_automation nologin;
  end if;
end $$;

create function is_staff() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from staff_members s where s.user_id = auth.uid() and s.is_active);
$$;

revoke all on schema public from anon;
grant usage on schema public to authenticated, absogrow_automation;

-- Start from nothing, then grant deliberately.
revoke all on all tables    in schema public from public, anon, authenticated, absogrow_automation;
revoke all on all functions in schema public from public, anon;
alter default privileges in schema public revoke all on tables    from public, anon;
alter default privileges in schema public revoke all on functions from public, anon;

grant execute on function is_staff()                                             to authenticated;
grant execute on function normalize_contact_value(contact_channel, text)         to authenticated, absogrow_automation;
grant execute on function mark_do_not_contact(uuid, suppression_reason, text, uuid) to authenticated, absogrow_automation;
grant execute on function advance_pipeline(uuid, pipeline_stage)                 to authenticated, absogrow_automation;
grant execute on function purge_expired_source_data()                            to absogrow_automation;

do $$
declare
  t text;
  -- what each role may do, per table
  staff_rw   text[] := array['businesses','business_locations','business_contacts','social_profiles',
                             'website_audits','audit_findings','competitor_research','digital_scores',
                             'commercial_scores','sales_pipeline','outreach_drafts','consent_records',
                             'incoming_replies','meetings','proposals','revenue_entries','notifications'];
  staff_ro   text[] := array['kenya_counties','staff_members','workflow_runs','integration_logs',
                             'pipeline_stage_history','audit_log','outreach_events'];
  auto_rw    text[] := array['businesses','business_locations','business_contacts','social_profiles',
                             'website_audits','audit_findings','competitor_research','digital_scores',
                             'commercial_scores','sales_pipeline','outreach_drafts','incoming_replies',
                             'meetings','notifications','workflow_runs','integration_logs'];
  auto_ro    text[] := array['kenya_counties','outreach_approvals','consent_records','proposals',
                             'pipeline_stage_history'];
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table %I enable row level security', t);
  end loop;

  foreach t in array staff_rw loop
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('create policy staff_all on %I for all to authenticated
                    using (is_staff()) with check (is_staff())', t);
  end loop;
  foreach t in array staff_ro loop
    execute format('grant select on %I to authenticated', t);
    execute format('create policy staff_read on %I for select to authenticated using (is_staff())', t);
  end loop;

  foreach t in array auto_rw loop
    execute format('grant select, insert, update on %I to absogrow_automation', t);
    execute format('create policy automation_all on %I for all to absogrow_automation
                    using (true) with check (true)', t);
  end loop;
  foreach t in array auto_ro loop
    execute format('grant select on %I to absogrow_automation', t);
    execute format('create policy automation_read on %I for select to absogrow_automation using (true)', t);
  end loop;
end $$;

-- Approvals: staff may read and add, as themselves. Nobody may change one.
grant select, insert on outreach_approvals to authenticated;
create policy staff_read on outreach_approvals for select to authenticated using (is_staff());
create policy staff_decide on outreach_approvals for insert to authenticated
  with check (is_staff() and decided_by = auth.uid());

-- Suppression list: both callers may read and add. Removal is a console job.
grant select, insert on suppression_list to authenticated, absogrow_automation;
create policy staff_read on suppression_list for select to authenticated using (is_staff());
create policy staff_add  on suppression_list for insert to authenticated with check (is_staff());
create policy automation_read on suppression_list for select to absogrow_automation using (true);
create policy automation_add  on suppression_list for insert to absogrow_automation with check (true);

-- Outreach events: automation records them (and the gate trigger decides
-- whether a queued/sent record is allowed).
grant select, insert on outreach_events to absogrow_automation;
create policy automation_read on outreach_events for select to absogrow_automation using (true);
create policy automation_add  on outreach_events for insert to absogrow_automation with check (true);

-- Automation may never mark a contact eligible; that is a human decision.
create function business_contacts_guard_eligibility() returns trigger
language plpgsql as $$
begin
  if current_user = 'absogrow_automation'
     and new.eligibility_status = 'eligible'
     and (tg_op = 'INSERT' or old.eligibility_status is distinct from 'eligible') then
    raise exception 'contact eligibility can only be granted by a staff member'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger business_contacts_guard_eligibility before insert or update on business_contacts
  for each row execute function business_contacts_guard_eligibility();

commit;
