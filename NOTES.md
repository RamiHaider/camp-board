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

## Layout and occupants loaded from the camp register (2026-11-11)
Source: "Registre des occupants" PDF dated 10-11-2026 from the camp. Rooms are one bed each: 37-62, 63-92 (only the numbers that appear on the register; 38, 66, 68, 70-72, 74, 76, 78, 91 are not listed), A1-A5, B1-B6. Four sections on the map: Rooms 37-62, Rooms 63-92, A rooms, B rooms. Adjust in Edit layout if the real camp differs (add beds per room, add the missing numbers).
- Register company codes mapped: SPEKTRA = Forage Spektra, MAPLE = Maple Gold Mines, FORAGE FTE = FTE Drilling, LAURENTIA = Laurentia Exploration. CINO and L'Hôte added to the dropdown.
- Jour/Nuit column kept as "Day shift" / "Night shift" at the start of each person's notes. "CM" suffix on a name moved to notes.
- Unknown departures (???, "Jamais", blank) got placeholder dates and a note saying so; weekly commuters (Lundi au Mercredi / Jeudi) got this week's dates and a "Weekly, …" note. Fix from the bed drawer when the real dates are known.
- The two one-night stays from the footnote (rooms 87 and 90 on Nov 10) are in History.

## Map = real floor plan (2026-11-11)
The Map tab draws the camp from the hand drawing, rotated 90 degrees to the right: the front (kitchen and deck) is at the left, room 37 at the far right. West wall (even rooms) on top, east wall (odd rooms) below, corridor between. Bloc B / Bloc A is the small building underneath with its two exits. The plan is a constant in `index.html` (`PLAN_WEST`, `PLAN_EAST`, `PLAN_BLOC_B`, `PLAN_BLOC_A`): room names there must match room names in the layout. A layout room not on the drawing shows under "Other rooms"; a drawing room not in the layout shows greyed with a tooltip. Edit layout still works (beds per room, names) and uses the old card view while editing.
Under the plan: "People in camp" roster with a search box (name, company, room, notes). Click a row to light the room up with an arrow; click a room to light up the row. Hover a bed for the details card.

## Company portals, shifts, change requests, exports (2026-11-12)
- **Roles** are now admin / viewer / company. A company login (`members.role = 'company'`, `members.company = name`) sees only its own company's people under "My people", can file new requests (company locked on the form) and **Change dates** requests, and nothing else. Row-level security enforces it; the page only hides buttons.
- **Change requests** (`change_requests` table): a company picks new dates (quick +1 / +2 / +7 days), gives a contact email, sends. Admins see them at the top of People with Approve / Decline. Approve applies the dates to the stay (bed-clash checked), both sides get email. A newer request on the same stay replaces the older pending one.
- **Shift** (`stays.shift`, day/night) is asked per person on the request form, shown as a chip everywhere, editable by admins in the bed drawer and the Edit-request drawer. Register import: people whose notes started "Night shift" were set to night (10 people).
- **Notes** are editable by admins: bed drawer ("Save changes") and the Edit button on waiting requests.
- **Exports** on the Map toolbar (admins and viewers): *Print floor plan* (every room in drawing order with name, company, shift, dates, notes, plus a full table and waiting requests; landscape, save as PDF from the print dialog), *Print departures* (per day, leaving and arriving by room, for the next 7 days or this/next Mon–Sun week; overdue list at the end), *CSV* of everyone in camp or waiting.
- **Logins** (all portal logins are `<company>@mgmcamp.com`, not real inboxes, so no password reset; an admin rotates them in the database). Who has access is listed on the Admin tab. Adding a login = `members` row + auth user (see the create_login pattern used on 2026-11-12).
- Maple Gold Mines has no company portal; MGM people are handled by admins.

## Company map + French (2026-11-12, later)
- A company login's home is the **Map**: its own people by name, every other occupied bed hatched grey as "Reserved" (no name, no company), free beds green. Data comes from `bed_occupancy()` (bed, arrive, depart only; members only). The roster, stats and "My people" lists show only the company's own people. No exports, no Add person.
- **FR / EN button** in the header. The page is written in English; French is applied to the DOM after each render from the `FR` dictionary and `FR_RX` patterns in `index.html` (add new UI strings there, in both). Choice is remembered per browser; default follows the browser language. Dates follow the language. `notranslate` meta stops Chrome's Google Translate from fighting it.

## Known limits
- Free Supabase projects pause after 7 days with no traffic; click Restore in the dashboard.
- GitHub Pages caches the page for ~10 minutes; hard refresh (Ctrl+Shift+R) after a deploy.
- The shared viewer account has no real inbox, so no password reset; an admin rotates it in the database.
