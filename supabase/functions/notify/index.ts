// Camp Board notifications. Called by the stays_notify database trigger (see supabase/schema.sql).
// Sends: receipt to requester + heads-up to admins on a new request; confirmation to requester on
// assignment or change; decline note; date-change requests from company portals and their decisions;
// feedback from the page's Feedback button to the maintainer. Secrets: RESEND_API_KEY (Edge Function secret).
import { createClient } from "npm:@supabase/supabase-js@2";

const SITE = "https://mgmcamp.com";
const FROM = "MGM Camp Board <noreply@mgmcamp.com>";
const FEEDBACK_TO = ["rahaider@maplegoldmines.com"]; // the site maintainer; bugs and UX notes from the Feedback button land here

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);

const fmt = (d?: string | null) => d ? new Date(d.slice(0, 10) + "T12:00:00Z").toLocaleDateString("en-CA", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }) : "—";
const esc = (s: unknown) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

function bedLabel(layout: any, key: string | null) {
  if (!key || !layout) return "—";
  const [s, r, n] = key.split("/");
  const sec = layout.sections?.find((x: any) => x.id === s);
  const room = sec?.rooms?.find((x: any) => x.id === r);
  return sec && room ? `${sec.name}, ${room.name}, bed ${n}` : key;
}

function wrap(title: string, body: string) {
  return `<!doctype html><html><body style="margin:0;background:#f6f4ef;font-family:Lato,Arial,sans-serif;color:#1c1a16">
  <div style="max-width:560px;margin:0 auto;padding:24px 16px">
    <div style="background:#121212;border-bottom:2px solid #d7b973;padding:14px 18px;border-radius:10px 10px 0 0">
      <div style="color:#f5f1e6;font-weight:700;letter-spacing:.08em;text-transform:uppercase;font-size:14px">Maple Gold Mines</div>
      <div style="color:#d7b973;font-weight:700;letter-spacing:.18em;font-size:10px">CAMP BOARD</div>
    </div>
    <div style="background:#fff;border:1px solid #d9d3c4;border-top:0;border-radius:0 0 10px 10px;padding:18px">
      <h2 style="margin:0 0 10px;font-size:17px">${esc(title)}</h2>
      ${body}
    </div>
    <p style="color:#6a6457;font-size:12px;margin:12px 4px 0">This message was sent automatically by the camp bed board. Replies are not read; contact the camp coordinator directly.</p>
  </div></body></html>`;
}
const row = (k: string, v: string) => `<tr><td style="padding:4px 10px 4px 0;color:#6a6457;white-space:nowrap">${esc(k)}</td><td style="padding:4px 0">${v}</td></tr>`;

async function send(to: string[], subject: string, html: string, replyTo?: string) {
  const key = Deno.env.get("RESEND_API_KEY");
  if (!key) { console.error("RESEND_API_KEY is not set"); return { skipped: true }; }
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: FROM, to, subject, html, ...(replyTo ? { reply_to: replyTo } : {}) }),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok) console.error("resend error", r.status, JSON.stringify(j));
  return { status: r.status, id: j.id };
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("nope", { status: 405 });
  const { data: settings } = await sb.from("settings").select("hook_secret").eq("id", "main").single();
  if (!settings || req.headers.get("x-camp-hook") !== settings.hook_secret) return new Response("forbidden", { status: 403 });

  const { event, stay_id, old, change_id, feedback_id } = await req.json();

  if (event === "feedback" && feedback_id) {
    const { data: f } = await sb.from("feedback").select("*").eq("id", feedback_id).single();
    if (!f) return new Response("no feedback", { status: 404 });
    const kind = ({ bug: "Bug", ux: "UX / UI", idea: "Idea", other: "Other" } as Record<string, string>)[f.kind] ?? "Other";
    const who = f.user_email ? `${f.user_email} (signed in)` : (f.email || "anonymous");
    const tbl = `<table style="font-size:14px;border-collapse:collapse">${row("Type", esc(kind))}${row("From", esc(who))}${f.page ? row("Page", esc(f.page)) : ""}${row("Sent", new Date(f.created_at).toLocaleString("en-CA", { timeZone: "America/Toronto" }))}${f.user_agent ? row("Browser", `<span style="color:#6a6457;font-size:12px">${esc(f.user_agent)}</span>`) : ""}</table>`;
    const msg = `<div style="white-space:pre-wrap;background:#f6f4ef;border:1px solid #d9d3c4;border-radius:8px;padding:12px;margin:12px 0;font-size:14px">${esc(f.message)}</div>`;
    const reply = f.email || f.user_email;
    const sent = await send(FEEDBACK_TO, `Camp Board feedback (${kind}): ${f.message.slice(0, 60).replace(/\s+/g, " ")}${f.message.length > 60 ? "…" : ""}`,
      wrap(`${kind} feedback`, `${tbl}${msg}${reply ? `<p style="margin:0;font-size:13px;color:#6a6457">Reply to <a href="mailto:${esc(reply)}" style="color:#a8842f">${esc(reply)}</a></p>` : ""}`), reply || undefined);
    return new Response(JSON.stringify({ event, sent: [sent] }), { headers: { "Content-Type": "application/json" } });
  }
  const [{ data: s }, { data: layoutRow }, { data: admins }] = await Promise.all([
    sb.from("stays").select("*").eq("id", stay_id).single(),
    sb.from("layout").select("sections").eq("id", "main").maybeSingle(),
    sb.from("members").select("email").eq("role", "admin"),
  ]);
  if (!s) return new Response("no stay", { status: 404 });
  const layout = layoutRow ?? null;
  const adminTo = (admins ?? []).map((a: any) => a.email);
  const out: any[] = [];
  const shift = s.shift === "night" ? "Night shift" : "Day shift";

  if (event === "requested") {
    const details = `<table style="font-size:14px;border-collapse:collapse">${row("Name", esc(s.name))}${row("Company", esc(s.company))}${row("Arrival", fmt(s.arrive))}${row("Departure", fmt(s.depart))}${row("Shift", shift)}${s.notes ? row("Notes", esc(s.notes)) : ""}</table>`;
    if (s.requester_email) out.push(await send([s.requester_email], `Bed request received: ${s.name}`, wrap("We got your request",
      `<p style="margin:0 0 10px">Your bed request is in the queue. The camp coordinator assigns rooms and you will get another email with the room and dates once it is done.</p>${details}`)));
    if (adminTo.length) out.push(await send(adminTo, `New bed request: ${s.name} (${s.company})`, wrap("New bed request",
      `${details}<p style="margin:12px 0 0">From ${esc(s.requester_email ?? "no email")}. <a href="${SITE}/#people" style="color:#a8842f;font-weight:700">Open the board</a> to assign a bed.</p>`)));
  }

  if ((event === "assigned" || event === "changed") && s.requester_email) {
    const bed = bedLabel(layout, s.bed);
    const datesChanged = s.req_arrive && (s.arrive !== s.req_arrive || s.depart !== s.req_depart);
    const moved = event === "changed" && old?.bed && old.bed !== s.bed;
    const title = event === "assigned" ? (datesChanged ? "Bed confirmed, with changed dates" : "Bed confirmed") : (moved ? "Your room has changed" : "Your stay dates have changed");
    const note = datesChanged ? `<p style="margin:10px 0 0;color:#8a5a00"><b>Note:</b> the dates differ from what was requested (${fmt(s.req_arrive)} to ${fmt(s.req_depart)}).</p>` : "";
    out.push(await send([s.requester_email], `${title}: ${s.name}`, wrap(title,
      `<table style="font-size:14px;border-collapse:collapse">${row("Name", esc(s.name))}${row("Company", esc(s.company))}${row("Room", `<b>${esc(bed)}</b>`)}${row("Arrival", fmt(s.arrive))}${row("Departure", fmt(s.depart))}${row("Shift", shift)}${row("Length of stay", `${Math.round((Date.parse(s.depart) - Date.parse(s.arrive)) / 86400000) + 1} days`)}</table>${note}`)));
  }

  if ((event === "change_requested" || event === "change_decided") && change_id) {
    const { data: c } = await sb.from("change_requests").select("*").eq("id", change_id).single();
    if (c) {
      const bed = bedLabel(layout, s.bed);
      const tbl = `<table style="font-size:14px;border-collapse:collapse">${row("Name", esc(s.name))}${row("Company", esc(s.company))}${row("Room", esc(bed))}${row("Current dates", `${fmt(s.arrive)} to ${fmt(s.depart)}`)}${row("Requested dates", `<b>${fmt(c.new_arrive)} to ${fmt(c.new_depart)}</b>`)}${c.note ? row("Reason", esc(c.note)) : ""}</table>`;
      if (event === "change_requested" && adminTo.length) {
        out.push(await send(adminTo, `Date change requested: ${s.name} (${s.company})`, wrap("Date change requested",
          `${tbl}<p style="margin:12px 0 0">Asked by ${esc(c.requested_by)}. <a href="${SITE}/#people" style="color:#a8842f;font-weight:700">Open the board</a> to approve or decline.</p>`)));
      }
      if (event === "change_decided") {
        const ok = c.status === "approved";
        const title = ok ? "Date change approved" : "Date change not approved";
        const body = ok
          ? `<p style="margin:0 0 10px">The new dates for <b>${esc(s.name)}</b> are confirmed: <b>${fmt(s.arrive)} to ${fmt(s.depart)}</b>, ${esc(bed)}.</p>`
          : `<p style="margin:0 0 10px">The camp coordinator could not approve the date change for <b>${esc(s.name)}</b>. The stay stays at ${fmt(s.arrive)} to ${fmt(s.depart)}.</p>`;
        const dn = c.decision_note ? `<p style="margin:10px 0 0"><b>Note from the coordinator:</b> ${esc(c.decision_note)}</p>` : "";
        const to = [c.requested_by]; if (ok && s.requester_email && s.requester_email !== c.requested_by) to.push(s.requester_email);
        out.push(await send(to, `${title}: ${s.name}`, wrap(title, body + tbl + dn)));
      }
    }
  }

  if (event === "declined" && s.requester_email) {
    out.push(await send([s.requester_email], `Bed request not approved: ${s.name}`, wrap("Request not approved",
      `<p style="margin:0">The camp coordinator could not approve the bed request for <b>${esc(s.name)}</b> (${esc(s.company)}, ${fmt(s.arrive)} to ${fmt(s.depart)}). Please contact the camp directly if you have questions.</p>`)));
  }

  return new Response(JSON.stringify({ event, sent: out }), { headers: { "Content-Type": "application/json" } });
});
