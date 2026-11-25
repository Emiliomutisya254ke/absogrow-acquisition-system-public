# Scoring rubric

Two independent scores, each out of 100. **The lead grade comes from the commercial opportunity score.** A high score never means you may contact someone; that depends on having a usable generic channel and the user's approval.

## Digital presence score (how strong their presence is now; higher = stronger)

| Part | Column in leads.csv | Max |
|---|---|---|
| Website quality and UX (loads, works on mobile, speed, navigation) | dp_website | 20 |
| SEO basics (title, description, headings, structured data, alt text) | dp_seo | 20 |
| Social media (linked profiles, completeness, recent activity seen) | dp_social | 20 |
| Brand consistency | dp_brand | 15 |
| Content | dp_content | 15 |
| Conversion paths (tap-to-call, WhatsApp, booking, forms) | dp_conversion | 10 |

## Commercial opportunity score (how good a lead; higher = better)

| Part | Column in leads.csv | Max |
|---|---|---|
| Clear, fixable problems found | co_problems | 20 |
| Potential business value (size, branches, price point) | co_value | 20 |
| Social media opportunity | co_social | 15 |
| Website and SEO opportunity | co_web | 15 |
| Growth potential | co_growth | 10 |
| Contact accessibility (a usable generic channel) | co_contact | 10 |
| Fit with the user's services | co_fit | 10 |

## Grades

| Grade | Commercial score |
|---|---|
| A | 80–100 |
| B | 65–79 |
| C | 45–64 |
| Low | below 45 |

## Notes from real use

- Business value and growth potential are judgements made from visible positioning. They are the least reliable parts, so say so in the notes.
- A business with a strong, recently built site usually scores low on opportunity. Don't draft for it.
- No generic email means `co_contact` is 0–3 and no draft is written; put the business on the call list instead.
- Every finding records: observation, evidence URL, why it matters, recommended fix, mapped service, confidence (low / medium / high).
