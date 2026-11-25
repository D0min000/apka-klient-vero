// Supabase Edge Function "send-quote": wysyła maila z wyceną do klienta z konta Gmail studia.
//
// Kto może jej użyć: tylko zalogowany właściciel (sprawdzamy to po stronie serwera).
// Do kogo wysyła: zawsze na adres zapisany w zapytaniu klienta, nigdy na adres z przeglądarki.
// Jak wysyła: SMTP Gmaila, port 465 (Supabase blokuje porty 25 i 587).
//
// Sekrety do ustawienia w Supabase (Edge Functions -> Secrets):
//   GMAIL_USER           np. vero.studiokontakt@gmail.com
//   GMAIL_APP_PASSWORD   hasło aplikacji Google (16 znaków, spacje nie mają znaczenia)
// SUPABASE_URL i SUPABASE_SERVICE_ROLE_KEY Supabase dodaje sam.

const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });
}

const enc = new TextEncoder();
const dec = new TextDecoder();

function b64(text: string): string {
  const bytes = enc.encode(text);
  let bin = '';
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Usuwa znaki końca linii, żeby nikt nie wstrzyknął własnych nagłówków maila. */
function oneLine(s: unknown): string {
  return String(s ?? '').replace(/[\r\n\u2028\u2029]+/g, ' ').trim();
}

function encodeHeader(s: string): string {
  return /^[\x20-\x7e]*$/.test(s) ? s : '=?UTF-8?B?' + b64(s) + '?=';
}

function wrap76(s: string): string {
  return (s.match(/.{1,76}/g) ?? ['']).join('\r\n');
}

export function buildMessage(o: { from: string; fromName: string; to: string; subject: string; body: string }): string {
  const body = o.body.replace(/\r\n|\r|\n/g, '\r\n');
  const headers = [
    `From: ${encodeHeader(oneLine(o.fromName))} <${oneLine(o.from)}>`,
    `To: <${oneLine(o.to)}>`,
    `Reply-To: <${oneLine(o.from)}>`,
    `Subject: ${encodeHeader(oneLine(o.subject))}`,
    `Date: ${new Date().toUTCString().replace('GMT', '+0000')}`,
    `Message-ID: <${crypto.randomUUID()}@vero-studio.local>`,
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=UTF-8',
    'Content-Transfer-Encoding: base64',
  ];
  return headers.join('\r\n') + '\r\n\r\n' + wrap76(b64(body)) + '\r\n';
}

type Conn = { read(p: Uint8Array): Promise<number | null>; write(p: Uint8Array): Promise<number>; close(): void };

class Smtp {
  buf = '';
  conn: Conn;
  constructor(conn: Conn) {
    this.conn = conn;
  }

  async fill(): Promise<void> {
    const chunk = new Uint8Array(4096);
    const n = await this.conn.read(chunk);
    if (n === null) throw new Error('Serwer poczty zamknął połączenie.');
    this.buf += dec.decode(chunk.subarray(0, n));
  }

  /** Czyta pełną odpowiedź serwera (także wielolinijkową, np. "250-...", "250 ..."). */
  async reply(): Promise<{ code: number; text: string }> {
    const lines: string[] = [];
    for (;;) {
      let idx: number;
      while ((idx = this.buf.indexOf('\r\n')) === -1) await this.fill();
      const line = this.buf.slice(0, idx);
      this.buf = this.buf.slice(idx + 2);
      lines.push(line);
      if (/^\d{3} /.test(line) || /^\d{3}$/.test(line)) {
        return { code: parseInt(line.slice(0, 3), 10), text: lines.join('\n') };
      }
    }
  }

  async send(line: string): Promise<void> {
    await this.conn.write(enc.encode(line + '\r\n'));
  }

  async expect(codes: number[], what: string): Promise<string> {
    const r = await this.reply();
    if (!codes.includes(r.code)) throw new SmtpError(r.code, what, r.text);
    return r.text;
  }

  async cmd(line: string, codes: number[], what: string): Promise<string> {
    await this.send(line);
    return this.expect(codes, what);
  }
}

export class SmtpError extends Error {
  code: number;
  stage: string;
  detail: string;
  constructor(code: number, stage: string, detail: string) {
    super(`SMTP ${code} (${stage})`);
    this.code = code;
    this.stage = stage;
    this.detail = detail;
  }
}

export async function sendMail(
  cfg: { host: string; port: number; user: string; pass: string },
  msg: { fromName: string; to: string; subject: string; body: string },
): Promise<void> {
  // @ts-ignore Deno.connectTls istnieje w środowisku Supabase Edge Functions
  const conn: Conn = await Deno.connectTls({ hostname: cfg.host, port: cfg.port });
  const smtp = new Smtp(conn);
  try {
    await smtp.expect([220], 'greeting');
    await smtp.cmd('EHLO vero-studio', [250], 'ehlo');
    await smtp.cmd('AUTH LOGIN', [334], 'auth');
    await smtp.cmd(b64(cfg.user), [334], 'auth-user');
    await smtp.cmd(b64(cfg.pass), [235], 'auth-pass');
    await smtp.cmd(`MAIL FROM:<${oneLine(cfg.user)}>`, [250], 'mail-from');
    await smtp.cmd(`RCPT TO:<${oneLine(msg.to)}>`, [250, 251], 'rcpt-to');
    await smtp.cmd('DATA', [354], 'data');
    const raw = buildMessage({ from: cfg.user, fromName: msg.fromName, to: msg.to, subject: msg.subject, body: msg.body });
    const stuffed = raw.replace(/^\./gm, '..'); // dot-stuffing z RFC 5321
    await conn.write(enc.encode(stuffed + '.\r\n'));
    await smtp.expect([250], 'data-end');
    try { await smtp.cmd('QUIT', [221], 'quit'); } catch (_) { /* wiadomość już wysłana */ }
  } finally {
    try { conn.close(); } catch (_) { /* nic */ }
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function rest(path: string, init: RequestInit = {}): Promise<Response> {
  const base = Deno.env.get('SUPABASE_URL')!;
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  return fetch(`${base}/rest/v1/${path}`, {
    ...init,
    headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) },
  });
}

export async function handle(req: Request): Promise<Response> {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });

  const base = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const gmailUser = oneLine(Deno.env.get('GMAIL_USER'));
  const gmailPass = String(Deno.env.get('GMAIL_APP_PASSWORD') ?? '').replace(/\s+/g, '');
  if (!base || !serviceKey) return json(500, { error: 'server_misconfigured' });
  if (!gmailUser || !gmailPass) return json(500, { error: 'mail_not_configured' });

  // 1. Kto pyta? Sprawdzamy token logowania w Supabase.
  const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
  if (!token) return json(401, { error: 'not_signed_in' });
  const who = await fetch(`${base}/auth/v1/user`, { headers: { apikey: serviceKey, Authorization: `Bearer ${token}` } });
  if (!who.ok) return json(401, { error: 'not_signed_in' });
  const user = await who.json();
  if (!user?.id || !UUID.test(user.id)) return json(401, { error: 'not_signed_in' });

  // 2. Czy to właściciel?
  const prof = await rest(`profiles?id=eq.${user.id}&select=role,approved`);
  const rows = prof.ok ? await prof.json() : [];
  if (!rows[0] || rows[0].role !== 'owner' || rows[0].approved !== true) return json(403, { error: 'not_owner' });

  // 3. Dane z żądania
  let input: { inquiryId?: string; subject?: string; body?: string };
  try { input = await req.json(); } catch (_) { return json(400, { error: 'bad_json' }); }
  const subject = oneLine(input.subject);
  const body = String(input.body ?? '');
  if (!input.inquiryId || !UUID.test(input.inquiryId)) return json(400, { error: 'bad_inquiry' });
  if (!subject || subject.length > 200) return json(400, { error: 'bad_subject' });
  if (!body.trim() || body.length > 10000) return json(400, { error: 'bad_body' });

  // 4. Adresata bierzemy z bazy, nie z żądania. Dzięki temu funkcja nie jest otwartym nadawcą spamu.
  const inq = await rest(`inquiries?id=eq.${input.inquiryId}&select=id,email,reply`);
  const found = inq.ok ? await inq.json() : [];
  if (!found[0]) return json(404, { error: 'inquiry_not_found' });
  const to = oneLine(found[0].email).toLowerCase();
  if (!EMAIL.test(to)) return json(400, { error: 'client_has_no_email' });
  if (!found[0].reply) return json(409, { error: 'no_quote_saved' });

  // 5. Wysyłka
  try {
    await sendMail(
      { host: Deno.env.get('SMTP_HOST') ?? 'smtp.gmail.com', port: Number(Deno.env.get('SMTP_PORT') ?? 465), user: gmailUser, pass: gmailPass },
      { fromName: 'Vero Studio', to, subject, body },
    );
  } catch (e) {
    if (e instanceof SmtpError) {
      console.error('SMTP', e.code, e.stage, e.detail);
      if (e.stage.startsWith('auth')) return json(502, { error: 'smtp_auth' });
      if (e.stage === 'rcpt-to') return json(502, { error: 'smtp_recipient_rejected' });
      return json(502, { error: 'smtp_failed' });
    }
    console.error('SMTP connection', e instanceof Error ? e.message : e);
    return json(502, { error: 'smtp_unreachable' });
  }

  // 6. Zapisujemy, że wysłano. Jeśli zapis się nie uda, mail i tak wyszedł, więc nie pokazujemy błędu wysyłki.
  const sentAt = new Date().toISOString();
  let saved = true;
  try {
    const patch = await rest(`inquiries?id=eq.${input.inquiryId}`, {
      method: 'PATCH',
      headers: { Prefer: 'return=minimal' },
      body: JSON.stringify({ reply: { ...(found[0].reply ?? {}), sentAt, sentTo: to } }),
    });
    saved = patch.ok;
  } catch (_) { saved = false; }
  return json(200, { ok: true, sentAt, to, saved });
}

// @ts-ignore Deno.serve istnieje w środowisku Supabase Edge Functions
Deno.serve(handle);
