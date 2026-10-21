/**
 * Cloudflare Worker: принимает заказ с лендинга и пересылает его в Telegram-бота.
 *
 * Переменные (Settings → Variables and Secrets):
 *   BOT_TOKEN       — токен бота от @BotFather (тип Secret!)
 *   CHAT_ID         — ID чата, куда бот присылает заказы
 *   ALLOWED_ORIGIN  — адрес сайта, например https://username.github.io
 */
export default {
  async fetch(request, env) {
    const origin = request.headers.get('Origin') || '';
    const allowed = env.ALLOWED_ORIGIN || '';
    const cors = {
      'Access-Control-Allow-Origin': allowed,
      'Access-Control-Allow-Methods': 'POST, OPTIONS',
      'Access-Control-Allow-Headers': 'Content-Type',
      'Vary': 'Origin'
    };

    if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
    if (request.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: cors });
    if (allowed && origin !== allowed) return new Response('Forbidden', { status: 403, headers: cors });

    let o;
    try { o = await request.json(); } catch { return new Response('Bad request', { status: 400, headers: cors }); }

    // Ловушка для спам-ботов: скрытое поле должно быть пустым
    if (o.website) return new Response('OK', { status: 200, headers: cors });

    const clean = (v, max) => String(v || '').trim().slice(0, max);
    const name = clean(o.name, 120), phone = clean(o.phone, 40), cemetery = clean(o.cemetery, 200);
    if (!name || !phone || !cemetery) return new Response('Missing fields', { status: 400, headers: cors });

    const lines = [
      '🕯 Новый заказ с сайта',
      '',
      'Имя: ' + name,
      'Телефон: ' + phone,
      'Кладбище: ' + cemetery,
      o.grave ? 'Имя на могиле: ' + clean(o.grave, 200) : '',
      'Тариф: ' + clean(o.tariff, 80),
      o.info ? 'Дополнительно: ' + clean(o.info, 1500) : ''
    ].filter(Boolean);

    const tg = await fetch(`https://api.telegram.org/bot${env.BOT_TOKEN}/sendMessage`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ chat_id: env.CHAT_ID, text: lines.join('\n') })
    });

    return new Response(tg.ok ? 'OK' : 'Telegram error', { status: tg.ok ? 200 : 502, headers: cors });
  }
};
