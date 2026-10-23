"""Builds index.html of graveangels.ru from site/schema.json + site/templates.

The content is edited in the CRM (module «Сайт»). On the server this script runs every minute:

  python3 site/build.py sync --out /var/www/graveangels     # push the schema, pull the published content, rebuild
  python3 site/build.py --out /var/www/graveangels          # build from the initial content in schema.json (no CRM)
  python3 site/build.py                                     # same, into the repository (index.html for GitHub)

Sync settings: /etc/graveangels/site.env (CRM_API, SITE_KEY, SITE_TOKEN) or the same environment variables.
Needs Python 3.10+ and Jinja2 (Ubuntu: apt install python3-jinja2).
"""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

from jinja2 import Environment, FileSystemLoader, select_autoescape
from markupsafe import Markup, escape

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SCHEMA = HERE / 'schema.json'
TEMPLATES = HERE / 'templates'
ENV_FILE = Path('/etc/graveangels/site.env')
ORDERS_ENV = Path('/etc/graveangels/orders.env')
DEFAULT_STATE = Path('/var/lib/graveangels/site-state.json')
# sizes downloaded for every CRM upload (the CRM resizes; one of its allowed widths)
WIDTHS = (480, 800, 1280, 2000)
ASSET = re.compile(r'^asset:([0-9a-f-]{36})$')


def nl2br(value):
    return Markup('<br>\n').join(escape(str(value)).split('\n'))


def fmt_number(n):
    """350 → «350», 1730 → «1 730», 12.5 → «12,5»."""
    cents = round(float(n) * 100)
    text = f'{cents // 100:,}'.replace(',', ' ')
    if cents % 100:
        text += ',' + f'{cents % 100:02d}'.rstrip('0')
    return text


class Images:
    """image(value) for the templates. CRM uploads become media/<id>-<w>.webp; the needed files are collected."""

    def __init__(self, out, dims):
        self.out = out
        self.dims = dims  # asset id → {width, height}, from the CRM
        self.needed = set()  # (asset id, requested width)

    def __call__(self, value, hint=None):
        if not value:
            return None
        m = ASSET.match(value)
        if not m:
            # a file of the website itself; a «-400» copy next to it becomes a srcset
            p = Path(value)
            small = p.with_name(f'{p.stem}-400{p.suffix}').as_posix()
            srcset = f'{small} 400w, {value} {hint}w' if hint and (self.out / small).exists() else None
            return {'src': value, 'srcset': srcset, 'width': None, 'height': None}
        aid = m.group(1)
        size = self.dims.get(aid) or {}
        orig = size.get('width') or WIDTHS[-1]
        widths = [w for w in WIDTHS if w < orig]
        top = next((w for w in WIDTHS if w >= orig), WIDTHS[-1])  # the CRM sends the original for this one
        files = [(w, w) for w in widths] + [(top, min(orig, top))]
        for w, _ in files:
            self.needed.add((aid, w))
        src = next((f'media/{aid}-{w}.webp' for w, real in files if real >= 800), f'media/{aid}-{files[-1][0]}.webp')
        srcset = ', '.join(f'media/{aid}-{w}.webp {real}w' for w, real in files)
        return {'src': src, 'srcset': srcset, 'width': size.get('width'), 'height': size.get('height')}


def page_context(content, initial):
    """Values the templates use besides the blocks: settings (s), tariffs for the order form."""
    def first(blocks, type_):
        return next((b for b in blocks if b.get('type') == type_), None)

    blocks = content.get('blocks') or []
    settings = first(blocks, 'settings') or first(initial['blocks'], 'settings') or {'data': {}}
    s = dict(settings.get('data') or {})
    s.setdefault('brand', '')
    s['whatsapp'] = re.sub(r'\D', '', s.get('whatsapp') or '')
    s['whatsapp_url'] = f"https://wa.me/{s['whatsapp']}"
    tg = (s.get('telegram') or '').strip().lstrip('@')
    s['telegram_url'] = f'https://t.me/{tg}' if tg else None
    phone = re.sub(r'[^\d+]', '', s.get('phone_link') or s.get('phone') or '')
    s['phone_url'] = f'tel:{phone}' if phone else None

    prices = first(blocks, 'prices')  # the form needs the tariffs even if the block is hidden
    data = (prices or {}).get('data') or {}
    currency = data.get('currency') or '₪'
    tariffs = []
    for i, t in enumerate(data.get('tariffs') or [], 1):
        price = t.get('price')
        tariffs.append({
            **t,
            'key': f't{i}',
            'price_text': f'{fmt_number(price)} {currency}' if price is not None else '',
            'old_price_text': f"{fmt_number(t['old_price'])} {currency}" if t.get('old_price') is not None else '',
        })
    return {
        's': s,
        'blocks': [b for b in blocks if not b.get('hidden')],
        'tariffs': tariffs,
        'tariffs_js': {t['key']: f"{t['name']} — {t['price_text']}" for t in tariffs},
        'first_tariff': tariffs[0]['key'] if tariffs else '',
    }


def render(content, out, order_endpoint='', dims=None):
    if order_endpoint and not re.fullmatch(r'/[A-Za-z0-9/_-]*', order_endpoint):
        raise SystemExit(f'Неверный адрес для заказов: {order_endpoint}')
    schema = json.loads(SCHEMA.read_text(encoding='utf-8'))
    env = Environment(loader=FileSystemLoader(TEMPLATES), autoescape=select_autoescape(['html']), trim_blocks=False)
    env.filters['nl2br'] = nl2br
    images = Images(out, dims or {})
    env.globals['image'] = images
    ctx = page_context(content, schema['initial'])
    types = {b['type']: b for b in schema['blocks']}
    # pinned blocks (header, footer) stay first / last whatever order the content has
    rank = {'top': 0, 'bottom': 2}
    ctx['blocks'] = sorted((b for b in ctx['blocks'] if b.get('type') in types), key=lambda b: rank.get(types[b['type']].get('pin'), 1))
    html = env.get_template('page.html').render(**ctx, order_endpoint=order_endpoint)
    return re.sub(r'\n{3,}', '\n\n', html), images.needed


def write_atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.tmp-')
    with os.fdopen(fd, 'wb') as f:
        f.write(data)
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


# ───────────── sync with the CRM ─────────────

def load_env():
    cfg = {}
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            if '=' in line and not line.lstrip().startswith('#'):
                k, v = line.split('=', 1)
                cfg[k.strip()] = v.strip().strip('"\'')
    for k in ('CRM_API', 'SITE_KEY', 'SITE_TOKEN'):
        cfg[k] = os.environ.get(k, cfg.get(k, ''))
    return cfg


class Crm:
    def __init__(self, cfg):
        self.base = cfg['CRM_API'].rstrip('/') + '/public/sites/' + cfg['SITE_KEY']
        self.headers = {'Authorization': f"Bearer {cfg['SITE_TOKEN']}"}

    def call(self, path, method='GET', body=None, raw=False):
        data = json.dumps(body, ensure_ascii=False).encode() if body is not None else None
        headers = {**self.headers, **({'Content-Type': 'application/json'} if data else {})}
        req = urllib.request.Request(self.base + path, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                payload = r.read()
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors='replace')[:300]
            raise SystemExit(f'CRM ответила {e.code} на {method} {path}: {detail}')
        except (urllib.error.URLError, TimeoutError) as e:
            raise SystemExit(f'CRM недоступна ({e}) — сайт остаётся как есть')
        return payload if raw else json.loads(payload)


def file_hash(*paths):
    h = hashlib.sha256()
    for p in paths:
        for f in sorted([p] if p.is_file() else p.rglob('*')):
            if f.is_file():
                h.update(f.relative_to(HERE).as_posix().encode())
                h.update(f.read_bytes())
    return h.hexdigest()


def sync(out, state_path, order_endpoint, force):
    cfg = load_env()
    if not all(cfg.get(k) for k in ('CRM_API', 'SITE_KEY', 'SITE_TOKEN')):
        raise SystemExit(f'Не настроена связь с CRM: нужны CRM_API, SITE_KEY и SITE_TOKEN в {ENV_FILE}')
    crm = Crm(cfg)
    state = json.loads(state_path.read_text()) if state_path.exists() else {}

    schema_hash = file_hash(SCHEMA)
    if state.get('schema') != schema_hash:
        crm.call('/schema', 'PUT', json.loads(SCHEMA.read_text(encoding='utf-8')))
        state['schema'] = schema_hash
        print('Описание блоков отправлено в CRM')

    pub = crm.call('/published')
    content = pub.get('content') or json.loads(SCHEMA.read_text(encoding='utf-8'))['initial']
    fingerprint = hashlib.sha256(
        json.dumps([pub.get('version'), content, order_endpoint, file_hash(TEMPLATES, SCHEMA, Path(__file__).resolve())], sort_keys=True, ensure_ascii=False).encode()
    ).hexdigest()
    if not force and state.get('page') == fingerprint and (out / 'index.html').exists():
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(state))
        return

    html, needed = render(content, out, order_endpoint, pub.get('assets'))
    media = out / 'media'
    for aid, w in sorted(needed):
        target = media / f'{aid}-{w}.webp'
        if not target.exists():
            write_atomic(target, crm.call(f'/assets/{aid}?w={w}', raw=True))
    write_atomic(out / 'index.html', html.encode('utf-8'))
    # pictures no longer on the page
    keep = {f'{aid}-{w}.webp' for aid, w in needed}
    for f in media.glob('*.webp') if media.exists() else []:
        if f.name not in keep:
            f.unlink()
    state['page'] = fingerprint
    state_path.parent.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps(state))
    print(f"Страница собрана: версия {pub.get('version') or 0} из CRM, картинок {len(keep)}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('mode', nargs='?', choices=['build', 'sync'], default='build')
    ap.add_argument('--out', type=Path, default=REPO, help='folder of the website (index.html is written there)')
    ap.add_argument('--content', type=Path, help='build: content JSON instead of the initial one')
    ap.add_argument('--order-endpoint', default='', help="'/api/order' when the server forwards orders; auto: if orders.env exists")
    ap.add_argument('--state', type=Path, default=DEFAULT_STATE)
    ap.add_argument('--force', action='store_true', help='sync: rebuild even if nothing changed')
    args = ap.parse_args()
    if args.order_endpoint == 'auto':
        args.order_endpoint = '/api/order' if ORDERS_ENV.exists() else ''
    if args.mode == 'sync':
        sync(args.out, args.state, args.order_endpoint, args.force)
        return
    content = json.loads(args.content.read_text(encoding='utf-8')) if args.content else json.loads(SCHEMA.read_text(encoding='utf-8'))['initial']
    html, needed = render(content, args.out, args.order_endpoint)
    if needed:
        sys.exit('В содержимом есть картинки из CRM — собирайте страницу командой sync')
    write_atomic(args.out / 'index.html', html.encode('utf-8'))
    print(f'Страница собрана: {args.out / "index.html"}')


if __name__ == '__main__':
    main()
