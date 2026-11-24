-- =====================================================================
-- Absogrow AI - Business Acquisition System
-- Migration 0003: Supabase hardening
--
-- A real Supabase project gives the roles "anon" and "authenticated"
-- EXECUTE on every new function and full rights on every new table in
-- schema public, through default privileges. Migration 0002 removed the
-- table rights but left function rights for "authenticated" in place.
-- Because Supabase lets anyone sign up by default, that would have let a
-- signed-in stranger call the helper routines below. This migration:
--   1. makes the two callable routines refuse a signed-in non-staff user;
--   2. removes EXECUTE from everyone, then grants back only what is needed;
--   3. stops future tables, sequences and functions being opened up by default;
--   4. pins search_path on every remaining function.
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- 1. Staff check inside the callable routines
--    auth.uid() is null for the automation role (no JWT), which reaches
--    these only through an explicit EXECUTE grant.
-- ---------------------------------------------------------------------
create or replace function advance_pipeline(p_business_id uuid, p_stage pipeline_stage) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null and not is_staff() then
    raise exception 'only staff may change the pipeline' using errcode = 'insufficient_privilege';
  end if;
  update sales_pipeline
     set stage = p_stage
   where business_id = p_business_id
     and stage < p_stage
     and stage not in ('won','lost','nurture','do_not_contact');
end $$;

create or replace function mark_do_not_contact(p_business_id uuid, p_reason suppression_reason,
                                               p_note text default null, p_reply_id uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if auth.uid() is not null and not is_staff() then
    raise exception 'only staff may mark a business do not contact' using errcode = 'insufficient_privilege';
  end if;

  update businesses
     set do_not_contact = true,
         do_not_contact_reason = coalesce(p_note, p_reason::text)
   where id = p_business_id;

  insert into suppression_list (channel, value_normalized, reason, business_id, source_reply_id, notes)
  select c.channel, c.value_normalized, p_reason, p_business_id, p_reply_id, p_note
    from business_contacts c
   where c.business_id = p_business_id
  on conflict (channel, value_normalized) do nothing;

  update business_contacts
     set eligibility_status = case when p_reason = 'unsubscribe' then 'opted_out'::eligibility_status
                                   else 'ineligible'::eligibility_status end,
         eligibility_basis = 'do not contact: ' || p_reason::text
   where business_id = p_business_id;

  update outreach_drafts
     set status = 'cancelled'
   where business_id = p_business_id
     and status in ('draft','awaiting_approval','approved','rewrite_requested');

  update sales_pipeline set stage = 'do_not_contact', next_action = null, next_action_at = null
   where business_id = p_business_id and stage <> 'do_not_contact';
end $$;

-- ---------------------------------------------------------------------
-- 2. Function and sequence privileges: remove everything, grant back the minimum
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
revoke all on all sequences in schema public from public, anon, authenticated;

grant execute on function is_staff()                                                to authenticated;
grant execute on function normalize_contact_value(contact_channel, text)            to authenticated, absogrow_automation;
grant execute on function mark_do_not_contact(uuid, suppression_reason, text, uuid) to authenticated, absogrow_automation;
grant execute on function advance_pipeline(uuid, pipeline_stage)                    to authenticated, absogrow_automation;
grant execute on function purge_expired_source_data()                               to absogrow_automation;

-- ---------------------------------------------------------------------
-- 3. Future objects start closed. Every later migration must grant
--    access explicitly.
-- ---------------------------------------------------------------------
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;
-- New functions are executable by everyone unless this global default is removed.
alter default privileges revoke execute on functions from public;

-- ---------------------------------------------------------------------
-- 4. Pin search_path on the functions that did not already set it
-- ---------------------------------------------------------------------
alter function set_updated_at()                              set search_path = public, pg_temp;
alter function normalize_contact_value(contact_channel, text) set search_path = public, pg_temp;
alter function business_contacts_normalize()                 set search_path = public, pg_temp;
alter function suppression_list_normalize()                  set search_path = public, pg_temp;
alter function retire_previous_score()                       set search_path = public, pg_temp;
alter function outreach_drafts_version()                     set search_path = public, pg_temp;
alter function forbid_change()                               set search_path = public, pg_temp;
alter function business_contacts_guard_eligibility()         set search_path = public, pg_temp;

commit;
