---
name: local-business-lead-audit
description: Find local businesses with a weak online presence in any city and sector, audit their website and social links on a phone-width view, score each one as a lead on two 100-point rubrics, and draft short evidence-based outreach emails that wait for your approval. Use when an agency, freelancer or consultant asks to "find leads", "prospect dentists in Leeds", "audit these business websites", "build a call list" or "draft cold emails from audit findings".
---

# Local Business Lead Audit

Turns "find me clients" into a scored, evidence-backed lead list and draft emails you can check and send yourself. Built from a working agency pipeline (Absogrow AI, Nairobi) that audited 65+ businesses in its first week.

**This skill never sends anything.** It researches, scores and drafts. The user reviews every draft and sends it from their own mailbox.

## Inputs to collect first

Ask in one message for anything missing, then start:

1. **Sector(s)**, e.g. dental clinics, hotels, opticians, restaurants.
2. **Town(s) or city**, e.g. "Leeds", "Lagos Island", "Austin, TX".
3. **Batch size.** Default 10; at most 20 per run.
4. **The user's services and offer**: what they sell (web design, SEO, social media, ads, automation) and the free thing they offer in a first email (default: "the full audit report with the fixes, at no cost").
5. **Sender details** for drafts: name, business name, city.
6. **Businesses to exclude**: existing clients and anyone already contacted.

## Workflow

Work one business at a time. Keep a running table in `templates/leads.csv` format.

### 1. Discover
- Use web search and map searches ("<sector> in <town>") and ordinary page visits.
- Do lookups one at a time. If a site shows a bot check or CAPTCHA, stop and move on. Never try to get around it.
- Skip chains and franchises with central marketing teams, plus anything on the exclude list.
- Record the name, website (or "none"), town, the source URL and any **generic** business email (info@, hello@, reception@). Do not collect named employees' personal emails or mobile numbers.

### 2. Audit each website
Follow `reference/audit-checklist.md`. Main points:
- Read the homepage at phone width (375 px) and wait until the page has fully loaded before counting anything.
- Run Google PageSpeed Insights for mobile, either at pagespeed.web.dev or with `scripts/pagespeed.py` (it calls Google's public PageSpeed API, nothing else).
- Check the title, meta description, headings, structured data, image alt text, forms, tap-to-call, a WhatsApp or booking link, analytics or ad pixel tags, and social links.
- **Before recording any "missing" claim, re-check it in the full page source.** Widgets, icons and structured data often hide links. This is where most false claims come from.

For a business with **no website**, record its map listing (rating and review count as seen, with the date) and its social pages. "Strong reviews, no website" is a lead type of its own.

### 3. Score
Use `reference/scoring-rubric.md`. Give each business two scores:
- **Digital presence** (0–100): how strong what they have now is.
- **Commercial opportunity** (0–100): how good a lead they are. **The grade comes from this score:** A 80+, B 65–79, C 45–64, Low below 45.

Write each finding as what was observed, the evidence URL, why it matters, the fix, the service it maps to, and your confidence. Run `scripts/score.py leads.csv` to check totals and assign grades.

### 4. Draft outreach (A and B leads with a generic email only)
Use `reference/email-template.md`:
- The subject line names their domain and the single strongest problem you verified.
- Give dated measurements ("on Tuesday 25 November"), never "today".
- Lead with one finding, then two more short ones, then the free offer and a single question.
- No prices, no discounts, no invented urgency.
- Every draft ends with an opt-out line.

Mark each draft `awaiting_approval`. Do not offer to send it.

### 5. Hand over
Give the user:
1. The leads table (CSV), sorted by grade.
2. The drafts, each with the findings it relies on and their evidence links.
3. A short summary: how many businesses were audited, the grade counts, the most common problems, and anything skipped and why.
4. Reminders: re-check each claim on the live site before sending, send from their own mailbox, and add anyone who replies "stop" to a do-not-contact list that is never emailed again.

## Rules

- **Nothing is sent by this skill.** The user approves and sends each email.
- **Generic business contacts only.** No personal emails of named staff, no scraped personal phone numbers.
- **No deception.** Every claim in a draft must be true and checkable at the evidence URL. If a finding cannot be verified, drop it.
- **Opt-outs.** Every email carries an opt-out line, and the user keeps a suppression list.
- **Local law.** Cold email to businesses is regulated differently in different places (for example GDPR/PECR in the UK and EU, CAN-SPAM in the US, Kenya's Data Protection Act). Tell the user once, in the summary, to check the rules that apply where they and their prospects are. This skill does not give legal advice.
- **Map data.** Do not copy Google Maps content (reviews, photos) into stored lead files beyond what the user needs for a call; note the rating as seen and the date.

## Files

- `reference/audit-checklist.md`: what to check on each site and how to avoid false claims
- `reference/scoring-rubric.md`: both rubrics, grades and scoring notes
- `reference/email-template.md`: first email, follow-up, call opener, no-website opener
- `templates/leads.csv`: column layout for the leads table
- `scripts/pagespeed.py`: mobile PageSpeed test through Google's public API (optional `PAGESPEED_API_KEY`)
- `scripts/score.py`: checks score parts against the rubric maximums and assigns grades
