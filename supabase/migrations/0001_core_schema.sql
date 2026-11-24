-- =====================================================================
-- Absogrow AI - Business Acquisition System
-- Migration 0001: core schema (tables, constraints, indexes, triggers)
-- Target: Supabase / PostgreSQL 15+
--
-- Design rules enforced in the database itself (not only in workflows):
--   1. Nothing can be recorded as queued/sent unless a staff member approved
--      that exact message version, the contact is marked eligible, and neither
--      the business nor the address is suppressed.            (outreach gate)
--   2. Approvals are append-only and snapshot the approved text.
--   3. Business facts live in businesses / business_locations; anything that
--      can identify a person lives in business_contacts with its own
--      eligibility status.
--   4. Source-restricted data (e.g. Google Places coordinates) carries an
--      expiry and is purged by purge_expired_source_data().
-- =====================================================================

begin;

-- ---------------------------------------------------------------------
-- Enumerated types
-- ---------------------------------------------------------------------
create type pipeline_stage as enum (
  'discovered','research_pending','audited','qualified','outreach_drafted',
  'awaiting_approval','approved','contacted','response_received','interested',
  'meeting_scheduled','proposal_sent','negotiation','won','lost','nurture',
  'do_not_contact');
create type lead_grade          as enum ('A','B','C','low');
create type confidence_level    as enum ('low','medium','high');
create type contact_channel     as enum ('email','phone','whatsapp','contact_form',
                                         'instagram_dm','facebook_messenger','linkedin','other');
create type contact_type        as enum ('generic_business','named_individual');
create type eligibility_status  as enum ('unverified','eligible','ineligible',
                                         'needs_legal_review','opted_out');
create type social_platform     as enum ('instagram','facebook','tiktok','linkedin','x',
                                         'youtube','whatsapp_business','other');
create type finding_area        as enum ('website','seo','social_media','brand','content',
                                         'conversion','competitor');
create type finding_kind        as enum ('verified_fact','observation','recommendation');
create type agency_service      as enum (
  'social_media_management','digital_marketing_strategy','paid_advertising','seo',
  'website_development','content_creation','digital_branding',
  'ai_business_automation','ai_agents','business_process_automation');
create type draft_status        as enum ('draft','awaiting_approval','approved','rejected',
                                         'rewrite_requested','sent','cancelled');
create type approval_decision   as enum ('approved','rejected','rewrite_requested','do_not_contact');
create type outreach_event_type as enum ('queued','sent','delivered','bounced','failed');
create type reply_classification as enum (
  'interested','requesting_information','requesting_pricing','wants_meeting',
  'not_interested','not_now','referral','out_of_office','unsubscribe','unclear');
create type lawful_basis        as enum ('consent','legitimate_interest','existing_relationship',
                                         'not_personal_data','other');
create type suppression_reason  as enum ('unsubscribe','do_not_contact','bounce','complaint',
                                         'legal','manual');
create type run_status          as enum ('running','succeeded','failed','partial');
create type notification_status as enum ('pending','sent','failed');
create type proposal_status     as enum ('draft','sent','accepted','declined','expired');
create type meeting_status      as enum ('proposed','scheduled','completed','cancelled','no_show');
create type audit_status        as enum ('pending','completed','failed');
create type staff_role          as enum ('owner','member');
create type revenue_kind        as enum ('one_off','recurring');

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- One normalisation rule shared by contacts and the suppression list, so a
-- suppressed address always matches however it was typed.
create function normalize_contact_value(p_channel contact_channel, p_value text)
returns text language plpgsql immutable as $$
declare v text := btrim(coalesce(p_value, ''));
begin
  if p_channel = 'email' then
    return lower(v);
  elsif p_channel in ('phone','whatsapp') then
    v := regexp_replace(v, '[^0-9+]', '', 'g');
    if v ~ '^0[0-9]{9}$'      then v := '+254' || substr(v, 2);      -- 07xx xxx xxx
    elsif v ~ '^254[0-9]{9}$' then v := '+' || v;                    -- 2547xx...
    end if;
    return v;
  else
    return lower(regexp_replace(v, '/+$', ''));
  end if;
end $$;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
create table kenya_counties (
  code smallint primary key check (code between 1 and 47),
  name text not null unique
);
insert into kenya_counties (code, name) values
 (1,'Mombasa'),(2,'Kwale'),(3,'Kilifi'),(4,'Tana River'),(5,'Lamu'),(6,'Taita-Taveta'),
 (7,'Garissa'),(8,'Wajir'),(9,'Mandera'),(10,'Marsabit'),(11,'Isiolo'),(12,'Meru'),
 (13,'Tharaka-Nithi'),(14,'Embu'),(15,'Kitui'),(16,'Machakos'),(17,'Makueni'),
 (18,'Nyandarua'),(19,'Nyeri'),(20,'Kirinyaga'),(21,'Murang''a'),(22,'Kiambu'),
 (23,'Turkana'),(24,'West Pokot'),(25,'Samburu'),(26,'Trans-Nzoia'),(27,'Uasin Gishu'),
 (28,'Elgeyo-Marakwet'),(29,'Nandi'),(30,'Baringo'),(31,'Laikipia'),(32,'Nakuru'),
 (33,'Narok'),(34,'Kajiado'),(35,'Kericho'),(36,'Bomet'),(37,'Kakamega'),(38,'Vihiga'),
 (39,'Bungoma'),(40,'Busia'),(41,'Siaya'),(42,'Kisumu'),(43,'Homa Bay'),(44,'Migori'),
 (45,'Kisii'),(46,'Nyamira'),(47,'Nairobi');

-- People allowed to use the CRM and approve outreach. user_id is the
-- Supabase auth user id.
create table staff_members (
  user_id      uuid primary key,
  display_name text not null,
  role         staff_role not null default 'member',
  is_active    boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Operations: workflow runs and integration calls
-- ---------------------------------------------------------------------
create table workflow_runs (
  id              uuid primary key default gen_random_uuid(),
  workflow_name   text not null,
  trigger_kind    text not null check (trigger_kind in ('schedule','manual','webhook','event')),
  status          run_status not null default 'running',
  idempotency_key text unique,              -- prevents the same run being processed twice
  items_in        integer not null default 0 check (items_in >= 0),
  items_out       integer not null default 0 check (items_out >= 0),
  error           text,
  started_at      timestamptz not null default now(),
  finished_at     timestamptz,
  check (finished_at is null or finished_at >= started_at)
);
create index workflow_runs_name_started_idx on workflow_runs (workflow_name, started_at desc);
create index workflow_runs_failed_idx on workflow_runs (started_at desc) where status in ('failed','partial');

create table integration_logs (
  id              uuid primary key default gen_random_uuid(),
  workflow_run_id uuid references workflow_runs(id) on delete set null,
  integration     text not null,            -- 'google_places','pagespeed','claude','gmail','telegram',...
  operation       text not null,
  success         boolean not null,
  status_code     integer,
  duration_ms     integer check (duration_ms is null or duration_ms >= 0),
  cost_usd        numeric(10,5) check (cost_usd is null or cost_usd >= 0),
  request_meta    jsonb not null default '{}'::jsonb,   -- never store keys, tokens or message bodies here
  error           text,
  created_at      timestamptz not null default now()
);
create index integration_logs_run_idx on integration_logs (workflow_run_id);
create index integration_logs_integration_idx on integration_logs (integration, created_at desc);
create index integration_logs_errors_idx on integration_logs (created_at desc) where not success;

-- ---------------------------------------------------------------------
-- Businesses (organisation-level facts only - no personal data here)
-- ---------------------------------------------------------------------
create table businesses (
  id                 uuid primary key default gen_random_uuid(),
  name               text not null check (btrim(name) <> ''),
  normalized_name    text generated always as
                       (regexp_replace(lower(name), '[^a-z0-9]+', '', 'g')) stored,
  industry           text,                  -- Absogrow sector label, e.g. 'hospitality'
  category           text,                  -- source category, e.g. Google primary type
  website_url        text check (website_url is null or website_url ~* '^https?://'),
  -- The business's OWN domain, lower-case, no scheme/www. Leave null when the
  -- "website" is a social page or directory listing, otherwise unrelated
  -- businesses would collide on the uniqueness rule below.
  website_domain     text check (website_domain is null
                                 or website_domain ~ '^[a-z0-9]([a-z0-9-]*\.)+[a-z]{2,}$'),
  google_place_id    text,
  discovery_source   text not null,         -- 'google_places','manual','referral',...
  source_url         text,
  discovered_at      timestamptz not null default now(),
  last_researched_at timestamptz,
  do_not_contact     boolean not null default false,
  do_not_contact_reason text,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create unique index businesses_place_id_uniq on businesses (google_place_id) where google_place_id is not null;
create unique index businesses_domain_uniq   on businesses (website_domain)  where website_domain  is not null;
create index businesses_normalized_name_idx  on businesses (normalized_name);
create index businesses_industry_idx         on businesses (industry);
create index businesses_discovered_idx       on businesses (discovered_at desc);
create trigger businesses_updated before update on businesses
  for each row execute function set_updated_at();

create table business_locations (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id) on delete cascade,
  label         text,
  address_line  text,
  town          text,
  county_code   smallint references kenya_counties(code),
  latitude      numeric(9,6) check (latitude  is null or latitude  between -5.5 and 5.5),
  longitude     numeric(9,6) check (longitude is null or longitude between 33.5 and 42.5),
  is_primary    boolean not null default false,
  data_source   text not null,              -- where this row's content came from
  source_url    text,
  -- Set when the source limits how long its content may be kept
  -- (Google Places coordinates: 30 days). Null = no source-imposed limit.
  retention_expires_at timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create unique index business_locations_primary_uniq on business_locations (business_id) where is_primary;
create index business_locations_business_idx on business_locations (business_id);
create index business_locations_county_idx   on business_locations (county_code);
create index business_locations_expiry_idx   on business_locations (retention_expires_at)
  where retention_expires_at is not null;
create trigger business_locations_updated before update on business_locations
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- Contacts (the only place contact details live; may be personal data)
-- ---------------------------------------------------------------------
create table business_contacts (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references businesses(id) on delete cascade,
  -- Defaults to the cautious reading: treat as personal data until someone
  -- confirms it is a generic business channel (info@, front-desk line).
  contact_type       contact_type not null default 'named_individual',
  channel            contact_channel not null,
  value              text not null check (btrim(value) <> ''),
  value_normalized   text not null,
  full_name          text,
  role_title         text,
  source_url         text not null,         -- where it was publicly listed
  collected_at       timestamptz not null default now(),
  -- A high lead score never changes this. Only a deliberate review does.
  eligibility_status eligibility_status not null default 'unverified',
  eligibility_basis  text,
  eligibility_reviewed_by uuid references staff_members(user_id),
  eligibility_reviewed_at timestamptz,
  retention_review_at timestamptz not null default (now() + interval '12 months'),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (business_id, channel, value_normalized),
  check (contact_type = 'named_individual' or full_name is null),
  check (eligibility_status <> 'eligible'
         or (eligibility_basis is not null and eligibility_reviewed_at is not null))
);
create index business_contacts_business_idx on business_contacts (business_id);
create index business_contacts_lookup_idx   on business_contacts (channel, value_normalized);
create index business_contacts_eligibility_idx on business_contacts (eligibility_status);

create function business_contacts_normalize() returns trigger
language plpgsql as $$
begin
  new.value_normalized := normalize_contact_value(new.channel, new.value);
  if new.channel = 'email' and new.value_normalized !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid email address: %', new.value using errcode = 'check_violation';
  end if;
  if tg_op = 'UPDATE' then new.updated_at := now(); end if;
  return new;
end $$;
create trigger business_contacts_normalize before insert or update on business_contacts
  for each row execute function business_contacts_normalize();

create table social_profiles (
  id             uuid primary key default gen_random_uuid(),
  business_id    uuid not null references businesses(id) on delete cascade,
  platform       social_platform not null,
  url            text not null check (url ~* '^https?://'),
  handle         text,
  is_official    boolean,                   -- null = not yet confirmed as the business's own page
  follower_count integer check (follower_count is null or follower_count >= 0),  -- public figure only
  last_post_at   date,
  posting_notes  text,
  observed_at    timestamptz not null default now(),
  source_url     text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (platform, url)
);
create index social_profiles_business_idx on social_profiles (business_id);
create trigger social_profiles_updated before update on social_profiles
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------
-- Research and audits
-- ---------------------------------------------------------------------
create table website_audits (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references businesses(id) on delete cascade,
  workflow_run_id  uuid references workflow_runs(id) on delete set null,
  status           audit_status not null default 'pending',
  audited_url      text,
  is_reachable     boolean,
  http_status      integer,
  is_https         boolean,
  is_mobile_friendly boolean,
  psi_performance  smallint check (psi_performance between 0 and 100),   -- measured by PageSpeed
  psi_seo          smallint check (psi_seo between 0 and 100),
  psi_accessibility smallint check (psi_accessibility between 0 and 100),
  psi_best_practices smallint check (psi_best_practices between 0 and 100),
  lcp_ms           integer check (lcp_ms is null or lcp_ms >= 0),
  cls              numeric(6,3) check (cls is null or cls >= 0),
  raw_measurements jsonb,                   -- trimmed tool output, kept as evidence
  ai_report        jsonb,                   -- validated structured report from the audit prompt
  ai_model         text,
  overall_confidence confidence_level,
  error            text,
  audited_at       timestamptz,
  created_at       timestamptz not null default now(),
  check (status <> 'completed' or (audited_at is not null and ai_report is not null))
);
create index website_audits_business_idx on website_audits (business_id, created_at desc);
create index website_audits_pending_idx  on website_audits (created_at) where status = 'pending';

create table audit_findings (
  id                   uuid primary key default gen_random_uuid(),
  audit_id             uuid not null references website_audits(id) on delete cascade,
  business_id          uuid not null references businesses(id) on delete cascade,
  area                 finding_area not null,
  kind                 finding_kind not null,     -- fact vs observation vs AI recommendation
  observation          text not null check (btrim(observation) <> ''),
  evidence_url         text,
  commercial_impact    text not null check (btrim(commercial_impact) <> ''),
  recommended_solution text not null check (btrim(recommended_solution) <> ''),
  agency_service       agency_service not null,
  confidence           confidence_level not null,
  severity             smallint not null default 2 check (severity between 1 and 3),
  created_at           timestamptz not null default now(),
  -- a "verified fact" without a source is not a verified fact
  check (kind <> 'verified_fact' or evidence_url is not null)
);
create index audit_findings_audit_idx    on audit_findings (audit_id);
create index audit_findings_business_idx on audit_findings (business_id);
create index audit_findings_service_idx  on audit_findings (agency_service);
create index audit_findings_area_idx     on audit_findings (area);

create table competitor_research (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null references businesses(id) on delete cascade,
  competitor_business_id uuid references businesses(id) on delete set null,
  competitor_name        text not null,
  competitor_url         text,
  observations           text not null,
  evidence_url           text,
  confidence             confidence_level not null default 'medium',
  researched_at          timestamptz not null default now(),
  check (competitor_business_id is null or competitor_business_id <> business_id)
);
create index competitor_research_business_idx on competitor_research (business_id);

-- ---------------------------------------------------------------------
-- Scores (two independent systems; history kept, one current row each)
-- ---------------------------------------------------------------------
create table digital_scores (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null references businesses(id) on delete cascade,
  audit_id               uuid references website_audits(id) on delete set null,
  website_ux             smallint not null check (website_ux between 0 and 20),
  seo                    smallint not null check (seo between 0 and 20),
  social_media           smallint not null check (social_media between 0 and 20),
  brand_consistency      smallint not null check (brand_consistency between 0 and 15),
  content_strategy       smallint not null check (content_strategy between 0 and 15),
  conversion             smallint not null check (conversion between 0 and 10),
  total                  smallint generated always as
    (website_ux + seo + social_media + brand_consistency + content_strategy + conversion) stored,
  rationale              jsonb not null default '{}'::jsonb,
  is_current             boolean not null default true,
  scored_at              timestamptz not null default now()
);
create unique index digital_scores_current_uniq on digital_scores (business_id) where is_current;
create index digital_scores_total_idx on digital_scores (total) where is_current;

create table commercial_scores (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid not null references businesses(id) on delete cascade,
  audit_id               uuid references website_audits(id) on delete set null,
  growth_opportunity     smallint not null check (growth_opportunity between 0 and 20),
  business_value         smallint not null check (business_value between 0 and 20),
  social_opportunity     smallint not null check (social_opportunity between 0 and 15),
  website_seo_opportunity smallint not null check (website_seo_opportunity between 0 and 15),
  growth_potential       smallint not null check (growth_potential between 0 and 10),
  contact_accessibility  smallint not null check (contact_accessibility between 0 and 10),
  service_fit            smallint not null check (service_fit between 0 and 10),
  total                  smallint generated always as
    (growth_opportunity + business_value + social_opportunity + website_seo_opportunity
     + growth_potential + contact_accessibility + service_fit) stored,
  -- Lead grade is taken from the commercial score: a weak digital presence is
  -- the opportunity, so a high digital score must not make a lead "A".
  grade                  lead_grade generated always as (
    case
      when (growth_opportunity + business_value + social_opportunity + website_seo_opportunity
            + growth_potential + contact_accessibility + service_fit) >= 80 then 'A'::lead_grade
      when (growth_opportunity + business_value + social_opportunity + website_seo_opportunity
            + growth_potential + contact_accessibility + service_fit) >= 65 then 'B'::lead_grade
      when (growth_opportunity + business_value + social_opportunity + website_seo_opportunity
            + growth_potential + contact_accessibility + service_fit) >= 45 then 'C'::lead_grade
      else 'low'::lead_grade
    end) stored,
  rationale              jsonb not null default '{}'::jsonb,
  is_current             boolean not null default true,
  scored_at              timestamptz not null default now()
);
create unique index commercial_scores_current_uniq on commercial_scores (business_id) where is_current;
create index commercial_scores_grade_idx on commercial_scores (grade, total desc) where is_current;

-- Inserting a new score retires the previous current one.
create function retire_previous_score() returns trigger
language plpgsql as $$
begin
  if new.is_current then
    execute format('update %I set is_current = false where business_id = $1 and is_current', tg_table_name)
      using new.business_id;
  end if;
  return new;
end $$;
create trigger digital_scores_retire before insert on digital_scores
  for each row execute function retire_previous_score();
create trigger commercial_scores_retire before insert on commercial_scores
  for each row execute function retire_previous_score();

-- ---------------------------------------------------------------------
-- Pipeline
-- ---------------------------------------------------------------------
create table sales_pipeline (
  id                   uuid primary key default gen_random_uuid(),
  business_id          uuid not null unique references businesses(id) on delete cascade,
  stage                pipeline_stage not null default 'discovered',
  stage_changed_at     timestamptz not null default now(),
  owner_id             uuid references staff_members(user_id),
  recommended_services agency_service[] not null default '{}',
  next_action          text,
  next_action_at       timestamptz,          -- drives follow-up reminders
  follow_up_count      smallint not null default 0 check (follow_up_count >= 0),
  lost_reason          text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index sales_pipeline_stage_idx    on sales_pipeline (stage);
create index sales_pipeline_followup_idx on sales_pipeline (next_action_at) where next_action_at is not null;
create index sales_pipeline_services_idx on sales_pipeline using gin (recommended_services);
create trigger sales_pipeline_updated before update on sales_pipeline
  for each row execute function set_updated_at();

create table pipeline_stage_history (
  id          uuid primary key default gen_random_uuid(),
  business_id uuid not null references businesses(id) on delete cascade,
  from_stage  pipeline_stage,
  to_stage    pipeline_stage not null,
  changed_by  uuid,
  changed_at  timestamptz not null default now()
);
create index pipeline_stage_history_business_idx on pipeline_stage_history (business_id, changed_at);

-- ---------------------------------------------------------------------
-- Outreach: drafts -> approvals -> events
-- ---------------------------------------------------------------------
create table outreach_drafts (
  id                 uuid primary key default gen_random_uuid(),
  business_id        uuid not null references businesses(id) on delete cascade,
  contact_id         uuid references business_contacts(id) on delete set null,
  audit_id           uuid references website_audits(id) on delete set null,
  parent_draft_id    uuid references outreach_drafts(id) on delete set null,
  channel            contact_channel not null,
  subject            text,
  body               text not null check (btrim(body) <> ''),
  is_follow_up       boolean not null default false,
  follow_up_number   smallint not null default 0 check (follow_up_number >= 0),
  status             draft_status not null default 'draft',
  version            integer not null default 1,
  content_hash       text not null,          -- maintained by trigger
  generated_by_model text,
  personalization_evidence jsonb not null default '[]'::jsonb,  -- finding ids the message relies on
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  check (channel <> 'email' or (subject is not null and btrim(subject) <> '')),
  check (is_follow_up = (follow_up_number > 0))
);
create index outreach_drafts_business_idx on outreach_drafts (business_id);
create index outreach_drafts_queue_idx    on outreach_drafts (created_at) where status = 'awaiting_approval';
create index outreach_drafts_status_idx   on outreach_drafts (status);

create table outreach_approvals (
  id                    uuid primary key default gen_random_uuid(),
  draft_id              uuid not null references outreach_drafts(id) on delete restrict,
  business_id           uuid not null references businesses(id) on delete restrict,
  decision              approval_decision not null,
  decided_by            uuid not null references staff_members(user_id),
  decided_at            timestamptz not null default clock_timestamp(),
  draft_version         integer not null,
  approved_subject      text,                -- snapshot of exactly what was approved
  approved_body         text,
  approved_content_hash text,
  notes                 text,
  check ((decision = 'approved') = (approved_content_hash is not null)),
  check (decision <> 'approved' or approved_body is not null)
);
create index outreach_approvals_draft_idx on outreach_approvals (draft_id, decided_at desc);

create table outreach_events (
  id                  uuid primary key default gen_random_uuid(),
  draft_id            uuid not null references outreach_drafts(id) on delete restrict,
  approval_id         uuid not null references outreach_approvals(id) on delete restrict,
  business_id         uuid not null references businesses(id) on delete restrict,
  contact_id          uuid references business_contacts(id) on delete set null,
  workflow_run_id     uuid references workflow_runs(id) on delete set null,
  channel             contact_channel not null,
  event_type          outreach_event_type not null,
  provider_message_id text,
  thread_id           text,
  error               text,
  occurred_at         timestamptz not null default now()
);
-- a draft can be sent exactly once
create unique index outreach_events_sent_once on outreach_events (draft_id) where event_type = 'sent';
create index outreach_events_business_idx on outreach_events (business_id, occurred_at desc);
create index outreach_events_thread_idx   on outreach_events (thread_id) where thread_id is not null;

-- ---------------------------------------------------------------------
-- Compliance: lawful basis records and suppression
-- ---------------------------------------------------------------------
create table consent_records (
  id            uuid primary key default gen_random_uuid(),
  contact_id    uuid not null references business_contacts(id) on delete cascade,
  business_id   uuid not null references businesses(id) on delete cascade,
  lawful_basis  lawful_basis not null,
  basis_detail  text not null check (btrim(basis_detail) <> ''),
  evidence_url  text,
  recorded_by   uuid not null references staff_members(user_id),
  recorded_at   timestamptz not null default now(),
  withdrawn_at  timestamptz
);
create index consent_records_contact_idx on consent_records (contact_id);

-- Deliberately not linked by foreign key to contacts: a suppressed address
-- must stay suppressed even if the contact or business row is later deleted.
create table suppression_list (
  id               uuid primary key default gen_random_uuid(),
  channel          contact_channel not null,
  value_normalized text not null check (btrim(value_normalized) <> ''),
  reason           suppression_reason not null,
  business_id      uuid references businesses(id) on delete set null,
  source_reply_id  uuid,
  notes            text,
  created_at       timestamptz not null default now(),
  unique (channel, value_normalized)
);

create function suppression_list_normalize() returns trigger
language plpgsql as $$
begin
  new.value_normalized := normalize_contact_value(new.channel, new.value_normalized);
  return new;
end $$;
create trigger suppression_list_normalize before insert on suppression_list
  for each row execute function suppression_list_normalize();

create table incoming_replies (
  id                  uuid primary key default gen_random_uuid(),
  business_id         uuid references businesses(id) on delete set null,
  contact_id          uuid references business_contacts(id) on delete set null,
  outreach_event_id   uuid references outreach_events(id) on delete set null,
  channel             contact_channel not null default 'email',
  provider_message_id text not null unique,   -- makes reply ingestion idempotent
  thread_id           text,
  from_address        text not null,
  subject             text,
  body_text           text,
  received_at         timestamptz not null,
  classification      reply_classification,
  classification_confidence confidence_level,
  classified_by_model text,
  needs_human_review  boolean not null default true,
  handled_at          timestamptz,
  created_at          timestamptz not null default now()
);
create index incoming_replies_business_idx on incoming_replies (business_id, received_at desc);
create index incoming_replies_unhandled_idx on incoming_replies (received_at) where handled_at is null;
create index incoming_replies_class_idx on incoming_replies (classification);

-- ---------------------------------------------------------------------
-- Meetings, proposals, revenue
-- ---------------------------------------------------------------------
create table meetings (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id) on delete cascade,
  status       meeting_status not null default 'proposed',
  scheduled_at timestamptz,
  location     text,
  sales_brief  jsonb,                        -- generated call-prep brief
  outcome      text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  check (status <> 'scheduled' or scheduled_at is not null)
);
create index meetings_business_idx on meetings (business_id);
create index meetings_upcoming_idx on meetings (scheduled_at) where status = 'scheduled';
create trigger meetings_updated before update on meetings
  for each row execute function set_updated_at();

create table proposals (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references businesses(id) on delete cascade,
  title         text not null,
  services      agency_service[] not null default '{}',
  status        proposal_status not null default 'draft',
  one_off_kes   numeric(14,2) not null default 0 check (one_off_kes >= 0),
  monthly_kes   numeric(14,2) not null default 0 check (monthly_kes >= 0),
  document_url  text,
  sent_at       timestamptz,
  decided_at    timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (status = 'draft' or sent_at is not null)
);
create index proposals_business_idx on proposals (business_id);
create index proposals_status_idx   on proposals (status);
create trigger proposals_updated before update on proposals
  for each row execute function set_updated_at();

-- Money actually received. The dashboard's "actual revenue" reads only this
-- table, so estimates in proposals can never be reported as revenue.
create table revenue_entries (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references businesses(id) on delete restrict,
  proposal_id  uuid references proposals(id) on delete set null,
  kind         revenue_kind not null,
  amount_kes   numeric(14,2) not null check (amount_kes > 0),
  received_on  date not null check (received_on <= current_date),
  reference    text,
  recorded_by  uuid references staff_members(user_id),
  created_at   timestamptz not null default now()
);
create index revenue_entries_business_idx on revenue_entries (business_id);
create index revenue_entries_date_idx     on revenue_entries (received_on);

-- ---------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------
create table notifications (
  id           uuid primary key default gen_random_uuid(),
  kind         text not null,                -- 'high_priority_lead','draft_awaiting_approval','workflow_failure',...
  business_id  uuid references businesses(id) on delete set null,
  channel      text not null default 'telegram',
  payload      jsonb not null default '{}'::jsonb,
  dedupe_key   text unique,                  -- the same alert is never sent twice
  status       notification_status not null default 'pending',
  attempts     smallint not null default 0 check (attempts >= 0),
  error        text,
  created_at   timestamptz not null default now(),
  sent_at      timestamptz
);
create index notifications_pending_idx on notifications (created_at) where status = 'pending';

-- ---------------------------------------------------------------------
-- Audit trail
-- ---------------------------------------------------------------------
create table audit_log (
  id          bigint generated always as identity primary key,
  table_name  text not null,
  row_id      uuid,
  action      text not null check (action in ('INSERT','UPDATE','DELETE')),
  actor_id    uuid,
  actor_role  text,
  old_row     jsonb,
  new_row     jsonb,
  occurred_at timestamptz not null default now()
);
create index audit_log_row_idx  on audit_log (table_name, row_id);
create index audit_log_time_idx on audit_log (occurred_at desc);

create function write_audit_log() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('UPDATE','INSERT') then to_jsonb(new) end;
begin
  -- Contact details are kept out of the trail so that deleting a contact
  -- really removes the personal data.
  if tg_table_name = 'business_contacts' then
    v_old := v_old - 'value' - 'value_normalized' - 'full_name' - 'role_title';
    v_new := v_new - 'value' - 'value_normalized' - 'full_name' - 'role_title';
  end if;
  insert into audit_log (table_name, row_id, action, actor_id, actor_role, old_row, new_row)
  values (tg_table_name,
          coalesce(v_new->>'id', v_old->>'id')::uuid,
          tg_op, auth.uid(),
          coalesce(nullif(current_setting('role', true), 'none'), session_user), v_old, v_new);
  return coalesce(new, old);
end $$;

do $$
declare t text;
begin
  foreach t in array array['businesses','business_contacts','outreach_drafts','outreach_approvals',
                           'outreach_events','consent_records','suppression_list','sales_pipeline',
                           'proposals','revenue_entries']
  loop
    execute format('create trigger %I after insert or update or delete on %I
                    for each row execute function write_audit_log()', t || '_audit', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Pipeline automation
-- ---------------------------------------------------------------------
create function businesses_create_pipeline() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into sales_pipeline (business_id) values (new.id) on conflict (business_id) do nothing;
  return new;
end $$;
create trigger businesses_create_pipeline after insert on businesses
  for each row execute function businesses_create_pipeline();

create function sales_pipeline_track_stage() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    insert into pipeline_stage_history (business_id, from_stage, to_stage, changed_by)
    values (new.business_id, null, new.stage, auth.uid());
  elsif new.stage is distinct from old.stage then
    new.stage_changed_at := now();
    insert into pipeline_stage_history (business_id, from_stage, to_stage, changed_by)
    values (new.business_id, old.stage, new.stage, auth.uid());
  end if;
  return new;
end $$;
create trigger sales_pipeline_track_insert after insert on sales_pipeline
  for each row execute function sales_pipeline_track_stage();
create trigger sales_pipeline_track_update before update on sales_pipeline
  for each row execute function sales_pipeline_track_stage();

-- Moves a business forward to p_stage, never backwards and never out of a
-- closed stage.
create function advance_pipeline(p_business_id uuid, p_stage pipeline_stage) returns void
language sql security definer set search_path = public, pg_temp as $$
  update sales_pipeline
     set stage = p_stage
   where business_id = p_business_id
     and stage < p_stage
     and stage not in ('won','lost','nurture','do_not_contact');
$$;

-- ---------------------------------------------------------------------
-- Do-not-contact: one routine, used by approvals, opt-out replies and staff
-- ---------------------------------------------------------------------
create function mark_do_not_contact(p_business_id uuid, p_reason suppression_reason,
                                    p_note text default null, p_reply_id uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
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
-- Draft versioning
-- ---------------------------------------------------------------------
create function outreach_drafts_version() returns trigger
language plpgsql as $$
begin
  new.content_hash := encode(sha256(convert_to(coalesce(new.subject, '') || E'\n\n' || new.body, 'UTF8')), 'hex');
  -- "approved" and "sent" are outcomes of an approval row or a send record.
  -- They are only ever set by those triggers (trigger depth 2+), never by a
  -- direct insert or update.
  if new.status in ('approved','sent')
     and (tg_op = 'INSERT' or new.status is distinct from old.status)
     and pg_trigger_depth() < 2 then
    raise exception 'draft status "%" can only be set through an approval or a recorded send', new.status
      using errcode = 'insufficient_privilege';
  end if;
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    if new.content_hash <> old.content_hash then
      if old.status = 'sent' then
        raise exception 'a sent message cannot be edited' using errcode = 'check_violation';
      end if;
      new.version := old.version + 1;
      -- editing an approved message withdraws the approval
      if old.status = 'approved' and new.status = 'approved' then
        new.status := 'awaiting_approval';
      end if;
    end if;
  end if;
  return new;
end $$;
create trigger outreach_drafts_version before insert or update on outreach_drafts
  for each row execute function outreach_drafts_version();

create function outreach_drafts_pipeline() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.status = 'awaiting_approval' then
    perform advance_pipeline(new.business_id, 'awaiting_approval');
  elsif new.status = 'draft' then
    perform advance_pipeline(new.business_id, 'outreach_drafted');
  end if;
  return new;
end $$;
create trigger outreach_drafts_pipeline after insert or update of status on outreach_drafts
  for each row execute function outreach_drafts_pipeline();

-- ---------------------------------------------------------------------
-- Approvals: human-only, append-only, snapshot what was approved
-- ---------------------------------------------------------------------
create function outreach_approvals_before() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare d outreach_drafts;
begin
  -- a signed-in user can only ever approve as themselves
  if auth.uid() is not null then new.decided_by := auth.uid(); end if;

  if new.decided_by is null or not exists
     (select 1 from staff_members s where s.user_id = new.decided_by and s.is_active) then
    raise exception 'approval must be recorded by an active staff member'
      using errcode = 'insufficient_privilege';
  end if;

  select * into d from outreach_drafts where id = new.draft_id for update;
  if not found then
    raise exception 'draft % does not exist', new.draft_id using errcode = 'foreign_key_violation';
  end if;
  if d.status <> 'awaiting_approval' then
    raise exception 'draft is "%", only drafts awaiting approval can be decided', d.status
      using errcode = 'check_violation';
  end if;

  new.business_id   := d.business_id;
  new.draft_version := d.version;
  new.decided_at    := clock_timestamp();
  if new.decision = 'approved' then
    new.approved_subject      := d.subject;
    new.approved_body         := d.body;
    new.approved_content_hash := d.content_hash;
  else
    new.approved_subject := null; new.approved_body := null; new.approved_content_hash := null;
  end if;
  return new;
end $$;
create trigger outreach_approvals_before before insert on outreach_approvals
  for each row execute function outreach_approvals_before();

create function outreach_approvals_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.decision = 'do_not_contact' then
    perform mark_do_not_contact(new.business_id, 'do_not_contact', new.notes);
  else
    update outreach_drafts
       set status = case new.decision when 'approved' then 'approved'::draft_status
                                      when 'rejected' then 'rejected'::draft_status
                                      else 'rewrite_requested'::draft_status end
     where id = new.draft_id;
    if new.decision = 'approved' then
      perform advance_pipeline(new.business_id, 'approved');
    end if;
  end if;
  return new;
end $$;
create trigger outreach_approvals_after after insert on outreach_approvals
  for each row execute function outreach_approvals_after();

create function forbid_change() returns trigger
language plpgsql as $$
begin
  raise exception '% rows are append-only', tg_table_name using errcode = 'insufficient_privilege';
end $$;
create trigger outreach_approvals_immutable before update or delete on outreach_approvals
  for each row execute function forbid_change();
create trigger audit_log_immutable before update or delete on audit_log
  for each row execute function forbid_change();
create trigger pipeline_stage_history_immutable before update or delete on pipeline_stage_history
  for each row execute function forbid_change();

-- ---------------------------------------------------------------------
-- THE OUTREACH GATE
-- A message can only be recorded as queued or sent when every condition
-- holds. Workflows must insert the 'queued' event BEFORE calling the mail
-- API; if this insert fails, nothing is sent.
-- ---------------------------------------------------------------------
create function outreach_events_gate() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  d outreach_drafts;
  a outreach_approvals;
  c business_contacts;
begin
  select * into d from outreach_drafts where id = new.draft_id for update;
  if not found then
    raise exception 'draft % does not exist', new.draft_id using errcode = 'foreign_key_violation';
  end if;
  new.business_id := d.business_id;
  new.contact_id  := d.contact_id;
  new.channel     := d.channel;

  if new.event_type not in ('queued','sent') then
    return new;                    -- delivery/bounce/failure records need no gate
  end if;

  select * into a from outreach_approvals where id = new.approval_id;
  if not found or a.draft_id <> new.draft_id or a.decision <> 'approved' then
    raise exception 'outreach blocked: no approval for this draft' using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from outreach_approvals x
              where x.draft_id = new.draft_id and x.decided_at > a.decided_at) then
    raise exception 'outreach blocked: approval was superseded by a later decision'
      using errcode = 'insufficient_privilege';
  end if;
  if d.status <> 'approved' or a.approved_content_hash <> d.content_hash then
    raise exception 'outreach blocked: message differs from the approved version or is not approved'
      using errcode = 'insufficient_privilege';
  end if;

  if d.contact_id is null then
    raise exception 'outreach blocked: draft has no contact' using errcode = 'insufficient_privilege';
  end if;
  select * into c from business_contacts where id = d.contact_id;
  if c.channel <> d.channel then
    raise exception 'outreach blocked: draft channel does not match contact channel'
      using errcode = 'insufficient_privilege';
  end if;
  if c.eligibility_status <> 'eligible' then
    raise exception 'outreach blocked: contact eligibility is "%"', c.eligibility_status
      using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from businesses b where b.id = d.business_id and b.do_not_contact) then
    raise exception 'outreach blocked: business is marked do not contact'
      using errcode = 'insufficient_privilege';
  end if;
  if exists (select 1 from suppression_list s
              where s.channel = c.channel and s.value_normalized = c.value_normalized) then
    raise exception 'outreach blocked: address is on the suppression list'
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;
create trigger outreach_events_gate before insert on outreach_events
  for each row execute function outreach_events_gate();

create function outreach_events_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.event_type = 'sent' then
    update outreach_drafts set status = 'sent' where id = new.draft_id;
    perform advance_pipeline(new.business_id, 'contacted');
  elsif new.event_type = 'bounced' and new.contact_id is not null then
    insert into suppression_list (channel, value_normalized, reason, business_id, notes)
    select c.channel, c.value_normalized, 'bounce', c.business_id, 'hard bounce'
      from business_contacts c where c.id = new.contact_id
    on conflict (channel, value_normalized) do nothing;
  end if;
  return new;
end $$;
create trigger outreach_events_after after insert on outreach_events
  for each row execute function outreach_events_after();
create trigger outreach_events_immutable before update or delete on outreach_events
  for each row execute function forbid_change();

-- ---------------------------------------------------------------------
-- Replies: opt-outs take effect the moment they are classified
-- ---------------------------------------------------------------------
create function incoming_replies_after() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.classification = 'unsubscribe'
     and (tg_op = 'INSERT' or old.classification is distinct from new.classification) then
    insert into suppression_list (channel, value_normalized, reason, business_id, source_reply_id)
    values (new.channel, new.from_address, 'unsubscribe', new.business_id, new.id)
    on conflict (channel, value_normalized) do nothing;
    if new.business_id is not null then
      perform mark_do_not_contact(new.business_id, 'unsubscribe', 'opt-out reply', new.id);
    end if;
  elsif new.business_id is not null and tg_op = 'INSERT' then
    perform advance_pipeline(new.business_id, 'response_received');
  end if;
  return new;
end $$;
create trigger incoming_replies_after after insert or update of classification on incoming_replies
  for each row execute function incoming_replies_after();

-- ---------------------------------------------------------------------
-- Retention
-- ---------------------------------------------------------------------
-- Run daily. Clears content whose source-imposed retention window has passed
-- and returns how many rows were touched.
create function purge_expired_source_data() returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare n integer;
begin
  update business_locations
     set latitude = null, longitude = null, retention_expires_at = null
   where retention_expires_at is not null and retention_expires_at <= now();
  get diagnostics n = row_count;
  return n;
end $$;

commit;
