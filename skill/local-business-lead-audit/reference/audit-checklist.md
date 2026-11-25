# Website audit checklist

Run this for each business that has a website. Note the date of every measurement.

## Load it properly
1. Open the homepage at phone width (375 px).
2. Wait until the page has fully loaded (`document.readyState === "complete"`, and no spinner). Slow sites need extra time or a read of the page source.
3. Read the contact page too; emails often live only there.

## Speed
- Run PageSpeed Insights for **mobile** (pagespeed.web.dev or `scripts/pagespeed.py <url>`).
- Record the performance score, Largest Contentful Paint (LCP) and total blocking time.
- "Unable to resolve" can also mean the site is just very slow. Retry once before recording a failure.

## Check, then record

| Area | What to check |
|---|---|
| SEO | `<title>` present and descriptive; meta description; one clear H1; structured data (LocalBusiness / Organization JSON-LD); image alt text (record a share such as "about half", not an exact count) |
| Conversion | Tap-to-call (`tel:` link), WhatsApp link (`wa.me` / `api.whatsapp.com`), booking or enquiry form that works, visible opening hours and location |
| Tracking | Google Analytics / Tag Manager, Meta pixel, other ad tags |
| Social | Icons that link to real, active profiles (not `#` or the platform's homepage); date of the latest post seen |
| Trust | HTTPS, copyright year, broken images or links, placeholder text left from a template |
| Contact | Generic business email(s) only |

## Avoiding false claims (most important)

Before writing "no X" anywhere:
1. Search the full page source for it (`tel:`, `wa.me`, `instagram.com`, `gtag(`, `fbq(` and so on).
2. Check the footer, the contact page, and any chat widget.
3. If you're still not sure, write "not found on the homepage on <date>" rather than "no X", or drop the claim.

In real use, about 1 in 10 first-pass claims turned out wrong on re-check. Re-checking is not optional.

## Businesses with no website
Record the map listing as seen (rating, number of reviews, date), any social pages, and whether booking-site listings (e.g. hotel aggregators) are their only online channel.
