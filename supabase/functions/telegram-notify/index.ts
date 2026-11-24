// telegram-notify: delivers pending rows from public.notifications to the owner's Telegram chat.
//
// Secret needed: TELEGRAM_BOT_TOKEN (set by the owner under Edge Functions > Secrets).
// The token is never written to the database, to logs or to a response.
// Deployed with JWT verification off: the caller must send the x-notify-secret header,
// which the database checks against a secret kept in Vault (migration 0005).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import postgres from "npm:postgres@3.4.9";

const dbUrl = Deno.env.get("SUPABASE_DB_URL");
const sql = dbUrl
  ? postgres(dbUrl, { max: 1, idle_timeout: 20, connect_timeout: 10, prepare: false })
  : null;

// The shared secret is 64 lowercase hex characters. Anything else is turned away
// without a database round trip.
const SECRET_SHAPE = /^[0-9a-f]{64}$/;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// Strip anything that could carry a credential before text leaves this function.
const clean = (s: string) =>
  s
    .replace(/postgres(ql)?:\/\/\S+/gi, "[database url]")
    .replace(/bot\d+:[\w-]+/g, "bot[token]")
    .replace(/\d{6,}:[\w-]{30,}/g, "[token]")
    .replace(/\b[0-9a-f]{64}\b/g, "[secret]")
    .slice(0, 200);

type Tg = { ok: boolean; status: number; description: string; result: unknown };

async function telegram(token: string, method: string, payload: Record<string, unknown>): Promise<Tg> {
  try {
    const res = await fetch(`https://api.telegram.org/bot${token}/${method}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
      signal: AbortSignal.timeout(10_000),
    });
    const data = await res.json().catch(() => null);
    return {
      ok: res.ok && data?.ok === true,
      status: res.status,
      description: clean(String(data?.description ?? "")),
      result: data?.result ?? null,
    };
  } catch (_e) {
    // The error text can contain the request URL, which holds the token, so it is not passed on.
    return { ok: false, status: 0, description: "network error or timeout calling Telegram", result: null };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json({ ok: false, reason: "method_not_allowed" }, 405);
  const secret = req.headers.get("x-notify-secret") ?? "";
  if (!SECRET_SHAPE.test(secret)) return json({ ok: false, reason: "unauthorized" }, 401);
  if (!sql) return json({ ok: false, reason: "internal_error" }, 500);

  let authorized = false;
  try {
    const [row] = await sql`select private.notify_state(${secret}) as state`;
    const state = row?.state as
      | { authorized?: boolean; chat_id?: number | null; pairing_code?: string | null }
      | undefined;
    if (state?.authorized !== true) return json({ ok: false, reason: "unauthorized" }, 401);
    authorized = true;

    const note = (status: string) => sql`select private.notify_set_status(${secret}, ${status})`;

    const token = Deno.env.get("TELEGRAM_BOT_TOKEN");
    if (!token) {
      await note("no_token: TELEGRAM_BOT_TOKEN is not set in Edge Function secrets");
      return json({ ok: false, reason: "no_token" });
    }

    let chatId: number | string | null = state.chat_id ?? null;

    if (chatId === null) {
      const code = state.pairing_code ?? null;
      if (!code) {
        await note("not_paired: no pairing code is set");
        return json({ ok: false, reason: "not_paired" });
      }
      const upd = await telegram(token, "getUpdates", { timeout: 0, allowed_updates: ["message"] });
      if (!upd.ok) {
        await note(`telegram_error on getUpdates: ${upd.status} ${upd.description}`);
        return json({ ok: false, reason: "telegram_error", detail: `${upd.status} ${upd.description}` });
      }
      // deno-lint-ignore no-explicit-any
      const updates = Array.isArray(upd.result) ? (upd.result as any[]) : [];
      const match = [...updates].reverse().find((u) =>
        u?.message?.chat?.type === "private" &&
        typeof u.message.text === "string" &&
        u.message.text.includes(code)
      );
      if (!match) {
        await note("waiting_for_pairing: the token works; no pairing message has arrived yet");
        return json({ ok: false, reason: "waiting_for_pairing" });
      }
      chatId = match.message.chat.id as number;
      const [paired] = await sql`select private.notify_pair(${secret}, ${String(chatId)}::bigint) as stored`;
      if (paired?.stored !== true) {
        // Another run stored a chat a moment ago. Leave delivery to the next run, which reads it.
        await note("ok: paired by another run");
        return json({ ok: true, sent: 0 });
      }
      await telegram(token, "sendMessage", {
        chat_id: chatId,
        text:
          "Absogrow alerts are connected. You will get a message here when a draft needs your approval, a reply comes in, a grade A lead is found or a research run finishes.",
      });
    }

    const items = await sql`select notification_id, body from private.notify_claim(${secret}, 20)`;
    if (items.length === 0) {
      await note("ok: connected, nothing pending");
      return json({ ok: true, sent: 0 });
    }

    // deno-lint-ignore no-explicit-any
    const lines = items.map((i: any) => String(i.body));
    let text = items.length === 1
      ? `Absogrow\n${lines[0]}`
      : `Absogrow: ${items.length} updates\n` + lines.map((l: string) => `- ${l}`).join("\n");
    if (text.length > 3900) text = text.slice(0, 3880) + "\n... more in the CRM";

    const sent = await telegram(token, "sendMessage", {
      chat_id: chatId,
      text,
      link_preview_options: { is_disabled: true },
    });
    // deno-lint-ignore no-explicit-any
    const ids = items.map((i: any) => String(i.notification_id)).join(",");
    const err = sent.ok ? null : `${sent.status} ${sent.description}`;
    await sql`select private.notify_result(${secret}, string_to_array(${ids}, ',')::uuid[], ${sent.ok}, ${err})`;
    await note(sent.ok ? `ok: delivered ${items.length}` : `telegram_error on sendMessage: ${err}`);
    return json({ ok: sent.ok, sent: sent.ok ? items.length : 0, detail: err });
  } catch (e) {
    const detail = clean(e instanceof Error ? e.message : "unknown error");
    console.error(`telegram-notify failed: ${detail}`);
    // Callers that have not proved they hold the secret learn nothing about the fault.
    return json(authorized ? { ok: false, reason: "internal_error", detail } : { ok: false, reason: "internal_error" }, 500);
  }
});
