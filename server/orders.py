# Принимает заказ с сайта и пересылает его в Telegram и в CRM (модуль «Заявки с сайта»).
# Настройки — /etc/graveangels/orders.env: BOT_TOKEN, CHAT_ID и/или CRM_FORM_URL. Заказ принят, если дошёл хотя бы до одного.
import json, os, urllib.parse, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("BOT_TOKEN", "")
CHAT_ID = os.environ.get("CHAT_ID", "")
# http://127.0.0.1:4200/api/public/forms/<ключ формы>
CRM_FORM_URL = os.environ.get("CRM_FORM_URL", "")
SITE_URL = os.environ.get("SITE_URL", "https://graveangels.ru/")
ALLOWED = {s + "://" + h for s in ("https", "http") for h in ("graveangels.ru", "www.graveangels.ru")}


def clean(v, n):
    return str(v or "").strip()[:n]


def to_telegram(lines):
    data = urllib.parse.urlencode({"chat_id": CHAT_ID, "text": "\n".join(["🕯 Новый заказ с сайта", ""] + lines)}).encode()
    urllib.request.urlopen("https://api.telegram.org/bot" + TOKEN + "/sendMessage", data, timeout=15)


def to_crm(name, phone, lines, client_ip):
    # name and phone go to the contact, the rest — into the task «Обработать заявку»
    body = json.dumps({"name": name, "phone": phone, "message": "\n".join(lines[2:]), "page": SITE_URL}).encode()
    req = urllib.request.Request(CRM_FORM_URL, body, {"Content-Type": "application/json", "X-Forwarded-For": client_ip})
    urllib.request.urlopen(req, timeout=15)


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, text):
        body = text.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        origin = self.headers.get("Origin", "")
        if origin and origin not in ALLOWED:
            return self.reply(403, "Forbidden")
        try:
            size = min(int(self.headers.get("Content-Length") or 0), 20000)
            o = json.loads(self.rfile.read(size) or b"{}")
            if not isinstance(o, dict):
                raise ValueError
        except Exception:
            return self.reply(400, "Bad request")

        # Ловушка для спам-ботов: скрытое поле должно быть пустым
        if o.get("website"):
            return self.reply(200, "OK")

        name, phone, cemetery = clean(o.get("name"), 120), clean(o.get("phone"), 40), clean(o.get("cemetery"), 200)
        if not (name and phone and cemetery):
            return self.reply(400, "Missing fields")

        lines = ["Имя: " + name, "Телефон: " + phone, "Кладбище: " + cemetery]
        if o.get("grave"):
            lines.append("Имя на могиле: " + clean(o.get("grave"), 200))
        lines.append("Тариф: " + clean(o.get("tariff"), 80))
        if o.get("info"):
            lines.append("Дополнительно: " + clean(o.get("info"), 1500))

        delivered = 0
        targets = []
        if TOKEN and CHAT_ID:
            targets.append(("telegram", lambda: to_telegram(lines)))
        if CRM_FORM_URL:
            targets.append(("crm", lambda: to_crm(name, phone, lines, self.headers.get("X-Real-IP", ""))))
        for target, send in targets:
            try:
                send()
                delivered += 1
            except Exception as e:
                print(target, "error:", e, flush=True)
        if not delivered:
            return self.reply(502, "Delivery error")
        self.reply(200, "OK")


ThreadingHTTPServer(("127.0.0.1", 8787), Handler).serve_forever()
