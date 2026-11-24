# Operations — how things are run

## Research batch (about 40 minutes for 15 businesses)
1. Pick sector + towns not yet covered. Exclude existing records and existing clients.
2. Discover names (web search, Google Maps search, ordinary page visits — one at a time; stop if a bot check appears).
3. For each site: load the homepage at 375 px, wait for `document.readyState === "complete"`, read title, description, headings, structured data, images/alt, forms, analytics/pixel tags, social links, WhatsApp/tap-to-call, contact emails (contact page too).
4. PageSpeed mobile test at pagespeed.web.dev, one tab per site.
5. Re-check every "not found" claim in the full page source (widgets, placeholder icons and structured data do not show as links).
6. Score both rubrics; save with one `execute_sql` per five businesses (JSON array in a DO block).
7. Draft emails for A/B leads with a generic email; save as `awaiting_approval`. Produce a review file for the owner.
8. Log a `workflow_runs` row and write a short report.

## Approval and sending
1. Owner approves in chat with explicit words ("send them all", "skip #8"). Record: contact eligible (basis text), `consent_records` row, `outreach_approvals` row quoting his words.
2. Send in business hours (9-11 EAT is best), only while the owner is present.
3. Before each send: re-check claims on the live site; open Gmail compose in the business mailbox, focus each field by script (if Gmail keyboard shortcuts are on, a stray keystroke acts on the mailbox), type recipient, subject, body; compare the fingerprint of the typed text with the approved hash; send; confirm "Message sent"; record queued + sent events.
4. The Gmail signature is added automatically — do not type a sign-off.

## Reply check
In Gmail, search `in:anywhere after:YYYY/MM/DD -from:me`. Confirm the right account is open first. Log a `workflow_runs` row (`reply_check`). Bounces → event `bounced`, contact `ineligible`. "stop" → suppression list.

## Telegram alerts
- Status: `select last_status, last_status_at, telegram_chat_id is not null as paired from private.notify_settings;`
- Force a run: `select private.dispatch_notifications();`
- Re-pair a new chat: set `telegram_chat_id = null, paired_at = null, pairing_code = encode(extensions.gen_random_bytes(4),'hex')`, then send `/start <code>` to the bot (in the bot's chat, not BotFather).
- When a draft's text changes, close its old pending alert by hand (status `expired`).

## Known quirks
- Free-plan Supabase pauses after a week without activity.
- If the Supabase connector's tools vanish, refresh the server's tool list.
- PageSpeed's "unable to resolve" also appears for merely slow sites.
- Counts read from a page (images, links) differ between phone and desktop widths; give shares, not exact counts, in emails.
