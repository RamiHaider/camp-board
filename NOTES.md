# Camp Board — decisions and notes

Live: https://mgmcamp.com · Database: Supabase project `camp-board` · Hosting: GitHub Pages from `main`.

## Access model
- **Anyone with the link** can open the request form and submit. No login, no code.
- **Viewer** (shared login) sees the map, people lists and history. Cannot change anything; the database refuses writes.
- **Admin** (named emails in the `members` table, role `admin`) can do everything.
- Add a person: insert a row in `members` with their email and role, then create their auth account.

## Company list is admin-gated (decided 2026-11-10)
Requesters pick a company from a dropdown or type a new one under "Other". A typed company is stored **on that request only** and never appears in the public dropdown. Reason: anything a random requester types would otherwise be shown to every other requester, and someone could put something offensive there. Only admins add or remove dropdown entries (Admin tab → Companies). When an admin assigns a request whose company is not in the list, the company is added to the list at that point, because an admin is vouching for it.

Seeded 2026-11-10 from the MGM `Project Invoicing/2026` vendor folders: Maple Gold Mines, Forage Spektra, RJLL, Explo-Logik, Major Drilling, FTE Drilling (Forages Technic-Eau), Laurentia Exploration. Colors: the seven seeded ones are fixed; a new company gets the next unused palette color automatically. Labs (AGAT, ALS) left out, they do not stay at camp.

## Notifications (LIVE 2026-11-11)
- Requester gives an email on the form; it is stored per request (`stays.requester_email`).
- Database trigger `stays_notify` → Edge Function `notify` → Resend, from `noreply@mgmcamp.com` (domain verified, DKIM + SPF CNAMEs in GoDaddy).
- Emails: receipt to requester + alert to every admin on a new request; confirmation with room, dates and length of stay on assignment (flags dates that differ from the request); room-change and date-change notes; decline note. Nothing on check-out.
- Secret: `RESEND_API_KEY` in Supabase Edge Function secrets (key `camp-board-send`, sending only). Trigger↔function shared secret lives in `settings.hook_secret`.
- Debug: `select * from net._http_response order by id desc` shows each call; function logs show Resend errors.

## Known limits
- Free Supabase projects pause after 7 days with no traffic; click Restore in the dashboard.
- GitHub Pages caches the page for ~10 minutes; hard refresh (Ctrl+Shift+R) after a deploy.
- The shared viewer account has no real inbox, so no password reset; an admin rotates it in the database.
