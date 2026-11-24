# Security and data protection

## Secrets
| Secret | Where it lives | Who sets it |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | Supabase > Edge Functions > Secrets | Owner only |
| Notify shared secret | Supabase Vault (`notify_shared_secret`), generated inside the database | Database |
| Supabase service keys | Provided to Edge Functions by Supabase automatically | Supabase |
| Gmail / Google account password | Owner's head / password manager | Owner only |

Nothing secret is stored in this repository. `.env` files are ignored by git. Claude never types or pastes a password, token or API key.

## Access control
- Row-level security on every table. Staff-only access through `is_staff()`.
- Schema `private` (alert settings and routines) is not reachable by `anon`, `authenticated`, `service_role` or the automation role.
- `telegram-notify` has JWT verification off but refuses any call without the 64-character secret header, which the database checks.
- Known and accepted advisor warnings: three SECURITY DEFINER functions callable by signed-in users (`advance_pipeline`, `is_staff`, `mark_do_not_contact`).

## Personal data (Kenya Data Protection Act 2019 and 2021 Regulations)
- Business information is kept separate from contact information (`business_contacts`).
- Only generic business channels are stored (info@, reservations@, a reception phone). Named staff emails are not collected.
- Each contact has an eligibility status. It becomes `eligible` only on the owner's recorded decision; a `consent_records` row states the basis ("other": cold email to a published generic business address, opt-out included, not reviewed by a lawyer).
- Every email carries an opt-out line. Any "stop" goes to `suppression_list` and blocks future sends at database level.
- From Google Places only the place ID is stored (Google terms). Ratings and phone numbers from Google Maps are used in the owner's call list, not stored in the database.
- Data is stored in London (eu-west-2). Cross-border transfer has not been reviewed.

**Not reviewed by a lawyer:** cold outreach to businesses, the lawful basis used, and storage outside Kenya. These are flagged for the owner's legal review.

## Retention
Source-restricted data carries an expiry date and is purged by `purge_expired_source_data()`. Contacts carry `retention_review_at` (one year after collection).
