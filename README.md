# Absogrow AI — Business Acquisition System

An AI-assisted system that finds Kenyan businesses with a weak digital presence, audits their websites and social pages, scores them as leads, drafts personalised outreach for the owner's approval, records approved sends, tracks replies and sends alerts to Telegram.

Built by Absogrow AI, a digital marketing and AI automation agency in Nairobi, Kenya.

> This is the public version of the project. Client and prospect names, contact details, research results and live infrastructure identifiers have been removed. The database schema, security model, alert function and working methods are complete.

## What it does

| Step | How it runs | Status |
|---|---|---|
| Discovery | Claude sessions: web search, Google Maps (Places) search, ordinary page visits | Working (manual runs) |
| Website audit | Homepage read at phone width in a browser + Google PageSpeed Insights mobile test | Working |
| Social audit | Links found on the website; web search by name | Shallow (no follower counts) |
| Scoring | Two 100-point scores; grade from the commercial score | Working (rubric v1) |
| Outreach drafts | Short, evidence-based emails tied to audit findings | Working |
| Approval | Owner approves in chat; the approval is recorded with his exact words and a hash of the text | Working (no approval UI yet) |
| Sending | Owner's business Gmail, one email at a time, text fingerprint checked before each send | Working |
| Reply check | Gmail search | Working (manual) |
| Alerts | Telegram bot via a Supabase Edge Function, triggered from the database | Live |
| Dashboard | Claude artifact reading Supabase live | Built |

Pilot results (no names) are in [docs/results-summary.md](docs/results-summary.md).

## Repository layout

```
README.md
skill/local-business-lead-audit/   general version packaged as an agent skill
docs/
  architecture.md          components and data flow (with diagram)
  security-and-data-protection.md
  scoring-rubric.md
  outreach-and-sales.md    email structure, call script, openers, follow-ups
  operations.md            how to run a research batch, send, check replies, maintain alerts
  costs.md
  results-summary.md       anonymised pilot and batch results
supabase/
  migrations/              0001-0005
  functions/telegram-notify/index.ts
.env.example               names of the secrets the system needs (no values)
```

## Run it as an agent skill

`skill/local-business-lead-audit/` is a general version of this system packaged as a SKILL.md skill for AI agents (Claude Code, Cursor, Codex). It works for any city and sector, contains no lead data, and never sends email by itself.

To try it in Claude Code, copy the folder into `~/.claude/skills/` and ask for, say, "10 dental clinics in Machakos".

## Setting up a database from this repo

1. Create a Supabase project (or run `supabase start` locally).
2. In `supabase/migrations/0005_notifications_delivery.sql`, replace `<your-project-ref>` with your project's reference.
3. Apply `supabase/migrations/0001` to `0005` in order (`supabase db push`, or paste each into the SQL editor).
4. Deploy the function: `supabase functions deploy telegram-notify --no-verify-jwt`.
5. Add the secret `TELEGRAM_BOT_TOKEN` under Edge Functions > Secrets. Never commit it.
6. Pair Telegram: read `select pairing_code from private.notify_settings;` and send `/start <code>` to your bot.

## Ground rules built into the system

- Nothing is sent without the owner's explicit approval of that exact text. The database refuses a send that has no matching approval.
- Only generic business contacts (info@, reception@) are stored; no named staff emails.
- Opt-outs are honoured at once and kept on a suppression list that blocks future sends.
- Existing clients are kept off prospect lists.
- No secrets in this repository, in chat or in logs.
