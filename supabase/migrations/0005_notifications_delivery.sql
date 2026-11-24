-- =====================================================================
-- Absogrow AI - Business Acquisition System
-- Migration 0005: Telegram notification delivery
--
-- How an alert travels:
--   1. A trigger on a business event writes a row to public.notifications.
--   2. A statement trigger on notifications (and a five-minute sweep) asks
--      the Edge Function "telegram-notify" to deliver whatever is pending.
--   3. The Edge Function holds the bot token as a function secret. The
--      token is never stored in the database.
--   4. The call is authorised by a random secret that is generated here,
--      kept in Vault and never leaves Supabase.
-- Nothing in schema "private" is reachable through the Data API.
-- A fault in any alert routine is logged as a warning and never blocks
-- the business write that caused it.
-- The script can be run again safely.
-- =====================================================================

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

create schema if not exists private;
comment on schema private is 'Internal objects for Telegram alert delivery. Not exposed through the Data API.';
revoke all on schema private from public, anon, authenticated, service_role, absogrow_automation;

-- ---------------------------------------------------------------------
-- 1. Settings (one row) and the shared secret
-- ---------------------------------------------------------------------
create table if not exists private.notify_settings (
  id               boolean primary key default true check (id),
  function_url     text not null,
  telegram_chat_id bigint,
  pairing_code     text,
  paired_at        timestamptz,
  last_status      text,
  last_status_at   timestamptz
);
alter table private.notify_settings enable row level security;
revoke all on private.notify_settings from public, anon, authenticated, service_role, absogrow_automation;

insert into private.notify_settings (function_url, pairing_code)
values ('https://<your-project-ref>.supabase.co/functions/v1/telegram-notify',
        encode(extensions.gen_random_bytes(4), 'hex'))
on conflict (id) do nothing;

-- 64 lowercase hex characters; the Edge Function rejects any other shape
-- before it touches the database.
select vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_shared_secret',
                           'Shared secret between the database and the telegram-notify Edge Function')
 where not exists (select 1 from vault.secrets where name = 'notify_shared_secret');

alter table public.notifications add column if not exists claimed_at timestamptz;

-- ---------------------------------------------------------------------
-- 2. Routines the Edge Function calls (it connects with the database URL)
-- ---------------------------------------------------------------------
create or replace function private.notify_authorized(p_secret text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(p_secret, '') <> '' and exists (
    select 1 from vault.decrypted_secrets s
     where s.name = 'notify_shared_secret' and s.decrypted_secret = p_secret);
$$;

create or replace function private.notify_state(p_secret text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s private.notify_settings;
begin
  if not private.notify_authorized(p_secret) then
    return jsonb_build_object('authorized', false);
  end if;
  select * into s from private.notify_settings;
  return jsonb_build_object('authorized', true,
                            'chat_id', s.telegram_chat_id,
                            'pairing_code', s.pairing_code);
end $$;

create or replace function private.notify_set_status(p_secret text, p_status text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.notify_authorized(p_secret) then return; end if;
  update private.notify_settings set last_status = left(p_status, 300), last_status_at = now();
end $$;

-- Returns true only for the call that actually stored the chat.
create or replace function private.notify_pair(p_secret text, p_chat_id bigint) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if not private.notify_authorized(p_secret) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;
  update private.notify_settings
     set telegram_chat_id = p_chat_id, paired_at = now(), pairing_code = null
   where telegram_chat_id is null;
  return found;
end $$;

create or replace function private.notify_claim(p_secret text, p_limit int default 20)
returns table (notification_id uuid, body text)
language plpgsql security definer set search_path = '' as $$
begin
  if not private.notify_authorized(p_secret) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;

  -- An alert about a draft is pointless once the draft has been decided,
  -- and no alert is worth sending three days late.
  update public.notifications n
     set status = 'expired',
         error  = 'Not sent: the draft was decided before the alert could be delivered.'
   where n.status = 'pending' and n.channel = 'telegram'
     and n.kind = 'draft_awaiting_approval' and n.payload ? 'draft_id'
     and not exists (select 1 from public.outreach_drafts d
                      where d.id::text = n.payload->>'draft_id' and d.status = 'awaiting_approval');
  update public.notifications n
     set status = 'expired',
         error  = 'Not sent: older than three days when delivery became possible.'
   where n.status = 'pending' and n.channel = 'telegram'
     and n.created_at < now() - interval '3 days';
  -- A run that died after claiming never reports back; stop retrying those too.
  update public.notifications n
     set status = 'failed',
         error  = coalesce(n.error, 'Gave up after five delivery attempts.')
   where n.status = 'pending' and n.channel = 'telegram' and n.attempts >= 5
     and (n.claimed_at is null or n.claimed_at < now() - interval '2 minutes');

  return query
  with picked as (
    select n.id
      from public.notifications n
     where n.status = 'pending' and n.channel = 'telegram'
       and (n.claimed_at is null or n.claimed_at < now() - interval '2 minutes')
     order by n.created_at
     limit greatest(1, least(coalesce(p_limit, 20), 50))
       for update skip locked
  )
  update public.notifications n
     set claimed_at = now(), attempts = n.attempts + 1
    from picked
   where n.id = picked.id
  returning n.id, coalesce(n.payload->>'text', n.kind || ': ' || n.payload::text);
end $$;

create or replace function private.notify_result(p_secret text, p_ids uuid[], p_ok boolean, p_error text default null)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not private.notify_authorized(p_secret) then
    raise exception 'unauthorized' using errcode = 'insufficient_privilege';
  end if;
  if p_ok then
    update public.notifications
       set status = 'sent', sent_at = now(), error = null
     where id = any(p_ids);
  else
    -- stays pending and is retried by the sweep; gives up after five attempts
    update public.notifications
       set error  = left(coalesce(p_error, 'delivery failed'), 300),
           status = case when attempts >= 5 then 'failed'::public.notification_status
                         else 'pending'::public.notification_status end
     where id = any(p_ids);
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. Asking the Edge Function to deliver
-- ---------------------------------------------------------------------
create or replace function private.dispatch_notifications() returns void
language plpgsql security definer set search_path = '' as $$
declare
  s        private.notify_settings;
  v_secret text;
begin
  select * into s from private.notify_settings;
  if not found then return; end if;

  if not exists (select 1 from public.notifications n
                  where n.status = 'pending' and n.channel = 'telegram'
                    and (n.claimed_at is null or n.claimed_at < now() - interval '2 minutes'))
     and not (s.telegram_chat_id is null and s.pairing_code is not null) then
    return;                          -- nothing to deliver and nothing to pair
  end if;

  select d.decrypted_secret into v_secret
    from vault.decrypted_secrets d where d.name = 'notify_shared_secret';
  if v_secret is null then return; end if;

  perform net.http_post(
    url     := s.function_url,
    body    := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    timeout_milliseconds := 20000);
exception when others then
  raise warning 'dispatch_notifications: %', sqlerrm;
end $$;

create or replace function private.notifications_dispatch_trg() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform private.dispatch_notifications();
  return null;
exception when others then
  raise warning 'notifications_dispatch_trg: %', sqlerrm;
  return null;
end $$;

create or replace trigger notifications_dispatch after insert on public.notifications
  for each statement execute function private.notifications_dispatch_trg();

-- ---------------------------------------------------------------------
-- 4. Turning business events into alerts
-- ---------------------------------------------------------------------
create or replace function private.enqueue_notification(p_kind text, p_text text,
                                                        p_business_id uuid default null,
                                                        p_dedupe text default null,
                                                        p_extra jsonb default '{}'::jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.notifications (kind, business_id, payload, dedupe_key)
  values (p_kind, p_business_id,
          coalesce(p_extra, '{}'::jsonb) ||
            jsonb_build_object('text', left(coalesce(p_text, p_kind), 600)),
          p_dedupe)
  on conflict (dedupe_key) do nothing;
exception when others then
  raise warning 'enqueue_notification: %', sqlerrm;
end $$;

-- A draft is waiting for the owner (new draft, or its text changed)
create or replace function private.notify_draft_awaiting() returns trigger
language plpgsql security definer set search_path = '' as $$
declare v_name text;
begin
  if new.status = 'awaiting_approval'
     and (tg_op = 'INSERT' or old.status is distinct from new.status
          or old.version is distinct from new.version) then
    select b.name into v_name from public.businesses b where b.id = new.business_id;
    perform private.enqueue_notification(
      'draft_awaiting_approval',
      'Draft awaiting your approval: ' || coalesce(v_name, 'unknown business') ||
        coalesce(' - "' || new.subject || '"', ''),
      new.business_id,
      'draft-' || new.id::text || '-v' || new.version::text,
      jsonb_build_object('draft_id', new.id));
  end if;
  return null;
exception when others then
  raise warning 'notify_draft_awaiting: %', sqlerrm;
  return null;
end $$;

create or replace trigger outreach_drafts_notify after insert or update of status, subject, body on public.outreach_drafts
  for each row execute function private.notify_draft_awaiting();

-- A reply was logged, or a logged reply turned out to be a warm one.
-- The message body and the sender address are deliberately left out.
create or replace function private.notify_reply() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_hot  boolean;
begin
  select b.name into v_name from public.businesses b where b.id = new.business_id;
  v_hot := coalesce(new.classification in ('interested','requesting_information','requesting_pricing',
                                           'wants_meeting','referral'), false);
  if tg_op = 'INSERT' then
    perform private.enqueue_notification(
      case when v_hot then 'interested_prospect' else 'reply_received' end,
      case when v_hot then 'INTERESTED: ' else 'Reply received: ' end ||
        coalesce(v_name, 'a sender not matched to a business') ||
        coalesce(' (' || replace(new.classification::text, '_', ' ') || ')', ' (not classified yet)') ||
        '. Open the CRM to read it.',
      new.business_id,
      'reply-' || new.id::text);
  elsif v_hot and new.classification is distinct from old.classification then
    perform private.enqueue_notification(
      'interested_prospect',
      'INTERESTED: ' || coalesce(v_name, 'a sender not matched to a business') ||
        ' (' || replace(new.classification::text, '_', ' ') || '). Open the CRM to read it.',
      new.business_id,
      'reply-' || new.id::text || '-' || new.classification::text);
  end if;
  return null;
exception when others then
  raise warning 'notify_reply: %', sqlerrm;
  return null;
end $$;

create or replace trigger incoming_replies_notify after insert or update of classification on public.incoming_replies
  for each row execute function private.notify_reply();

-- A new grade A lead (once per business)
create or replace function private.notify_grade_a() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_town text;
begin
  if new.grade = 'A' and new.is_current then
    select b.name into v_name from public.businesses b where b.id = new.business_id;
    select l.town into v_town from public.business_locations l
     where l.business_id = new.business_id order by l.is_primary desc limit 1;
    perform private.enqueue_notification(
      'high_priority_lead',
      'New grade A lead: ' || coalesce(v_name, 'unknown business') ||
        ' (' || new.total::text || ' of 100)' || coalesce(', ' || v_town, ''),
      new.business_id,
      'lead-a-' || new.business_id::text);
  end if;
  return null;
exception when others then
  raise warning 'notify_grade_a: %', sqlerrm;
  return null;
end $$;

create or replace trigger commercial_scores_notify after insert on public.commercial_scores
  for each row execute function private.notify_grade_a();

-- A research or outreach run finished or failed
create or replace function private.notify_run_finished() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status is distinct from old.status and new.status in ('succeeded','partial','failed') then
    perform private.enqueue_notification(
      'workflow_' || new.status::text,
      case when new.status = 'failed'
           then 'RUN FAILED: ' || new.workflow_name || coalesce(' - ' || left(new.error, 200), '')
           else 'Run finished: ' || new.workflow_name || ' (' || coalesce(new.items_out::text, '?') ||
                ' of ' || coalesce(new.items_in::text, '?') || ' done' ||
                case when new.status = 'partial' then ', partial' else '' end || ')'
      end,
      null,
      'run-' || new.id::text || '-' || new.status::text);
  end if;
  return null;
exception when others then
  raise warning 'notify_run_finished: %', sqlerrm;
  return null;
end $$;

create or replace trigger workflow_runs_notify after update of status on public.workflow_runs
  for each row execute function private.notify_run_finished();

-- ---------------------------------------------------------------------
-- 5. Sweep for retries and pairing, and housekeeping for the cron log
-- ---------------------------------------------------------------------
select cron.schedule('absogrow-notify-sweep', '*/5 * * * *', 'select private.dispatch_notifications()');
select cron.schedule('absogrow-cron-log-cleanup', '17 3 * * *',
                     $c$delete from cron.job_run_details where end_time < now() - interval '7 days'$c$);

-- ---------------------------------------------------------------------
-- 6. The one alert queued during the pilot is out of date: Telegram was
--    never connected and those six drafts were approved and sent.
-- ---------------------------------------------------------------------
update public.notifications
   set status = 'expired',
       error  = 'Not sent: Telegram was not connected, and the six pilot drafts were approved and sent on 20 Nov 2026.'
 where dedupe_key = 'pilot-2026-11-20-drafts' and status = 'pending';
