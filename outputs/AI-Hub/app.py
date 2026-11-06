import hmac
import hashlib
import json
import os
import secrets
import uuid
from datetime import datetime, timedelta
from decimal import Decimal
from functools import wraps

from cryptography.fernet import Fernet
from flask import Flask, g, jsonify, redirect, render_template, request, session
from flask.json.provider import DefaultJSONProvider
from psycopg import Error as DatabaseError
from psycopg.types.json import Jsonb
from werkzeug.exceptions import HTTPException
from werkzeug.middleware.proxy_fix import ProxyFix
from werkzeug.security import check_password_hash

from core import (MESSAGES, Problem, bool_value, cost, fail, hash_key, identifier, integer,
                  new_key, price, prompt_for, text, uid, validate_base_url, validate_result)
from database import Database
from proxy import ModelProxy


class JSONProvider(DefaultJSONProvider):
    @staticmethod
    def default(value):
        if isinstance(value, (uuid.UUID,)):
            return str(value)
        if isinstance(value, Decimal):
            return float(value)
        if isinstance(value, datetime):
            return value.isoformat()
        return DefaultJSONProvider.default(value)


def create_app(config=None):
    app = Flask(__name__)
    app.json = JSONProvider(app)
    app.config.update(
        SECRET_KEY=os.getenv('AI_HUB_SECRET_KEY'),
        DATABASE_URL=os.getenv('AI_HUB_DATABASE_URL'),
        ENCRYPTION_KEY=os.getenv('AI_HUB_ENCRYPTION_KEY'),
        ADMIN_PASSWORD_HASH=os.getenv('AI_HUB_ADMIN_PASSWORD_HASH'),
        LITELLM_URL=os.getenv('AI_HUB_LITELLM_URL', 'http://127.0.0.1:4000'),
        LITELLM_KEY=os.getenv('AI_HUB_LITELLM_KEY', ''),
        PUBLIC_ORIGIN=os.getenv('AI_HUB_PUBLIC_ORIGIN', 'https://ai.cliang.top'),
        SESSION_COOKIE_NAME='ai_hub_session', SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SECURE=os.getenv('AI_HUB_SECURE_COOKIE', '1') != '0',
        SESSION_COOKIE_SAMESITE='Strict', PERMANENT_SESSION_LIFETIME=timedelta(hours=12),
        MAX_CONTENT_LENGTH=128 * 1024,
    )
    if config:
        app.config.update(config)
    for name in ('SECRET_KEY', 'DATABASE_URL', 'ENCRYPTION_KEY', 'ADMIN_PASSWORD_HASH'):
        if not app.config.get(name):
            raise RuntimeError(f'AI Hub missing required setting: {name}')
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1)
    database = Database(app.config['DATABASE_URL'])
    cipher = Fernet(app.config['ENCRYPTION_KEY'])
    proxy = ModelProxy(app.config['LITELLM_URL'], app.config['LITELLM_KEY'], cipher)
    app.extensions.update(database=database, model_proxy=proxy, cipher=cipher)

    def body():
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            raise Problem('invalid_input', '需要发送 JSON 对象')
        return data

    def ok(**kwargs):
        return jsonify(ok=True, **kwargs)

    def csrf():
        token = request.headers.get('X-CSRF-Token', '')
        if not token or not hmac.compare_digest(session.get('csrf_token', ''), token):
            raise Problem('csrf_failed', '页面验证已过期，请刷新后重试', 403)
        origin = request.headers.get('Origin')
        if origin and origin.rstrip('/') != app.config['PUBLIC_ORIGIN'].rstrip('/'):
            raise Problem('csrf_failed', '页面来源无效', 403)

    def admin(fn):
        @wraps(fn)
        def wrapped(*args, **kwargs):
            if not session.get('admin'):
                raise Problem('unauthorized', '请先登录后台', 401)
            if request.method not in ('GET', 'HEAD'):
                csrf()
            return fn(*args, **kwargs)
        return wrapped

    def bearer(kind):
        def decorator(fn):
            @wraps(fn)
            def wrapped(*args, **kwargs):
                auth = request.headers.get('Authorization', '')
                if not auth.startswith('Bearer ') or not 20 < len(auth) < 200:
                    raise Problem('unauthorized', '访问凭据无效', 401)
                digest = hash_key(auth[7:])
                principal = database.app_for_key(digest, include_disabled=request.endpoint == 'app_config') if kind == 'app' else database.worker_for_key(digest)
                if not principal:
                    raise Problem('unauthorized', '访问凭据无效', 401)
                g.principal = principal
                return fn(*args, **kwargs)
            return wrapped
        return decorator

    @app.errorhandler(Problem)
    def problem(error):
        return jsonify(ok=False, error={'code': error.code, 'message': error.message}), error.status

    @app.errorhandler(HTTPException)
    def http_error(error):
        return jsonify(ok=False, error={'code': 'http_error', 'message': '请求不存在或格式无效'}), error.code

    @app.errorhandler(Exception)
    def exception(error):
        # Exceptions may contain SQL parameters, provider credentials or upstream response text.
        app.logger.error('request failed type=%s path=%s', type(error).__name__, request.path)
        return jsonify(ok=False, error={'code': 'internal_error', 'message': MESSAGES['internal_error']}), 503

    @app.after_request
    def headers(response):
        response.headers.update({
            'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff',
            'Referrer-Policy': 'no-referrer', 'X-Frame-Options': 'DENY',
            'Content-Security-Policy': "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'",
        })
        return response

    @app.get('/healthz')
    def health():
        with database.connect() as db:
            db.execute('SELECT 1')
        return ok(service='ai-hub', version='0.1.0')

    @app.get('/')
    def index():
        return render_template('dashboard.html') if session.get('admin') else redirect('/login')

    @app.get('/login')
    def login_page():
        return render_template('login.html')

    @app.get('/admin/api/session')
    def session_info():
        if 'csrf_token' not in session:
            session['csrf_token'] = secrets.token_urlsafe(32)
        return ok(authenticated=bool(session.get('admin')), csrf_token=session['csrf_token'])

    @app.post('/admin/login')
    def login():
        csrf()
        identity = 'admin:' + (request.remote_addr or 'unknown')
        if database.auth_limited(identity):
            raise Problem('rate_limited', '尝试次数过多，请 15 分钟后重试', 429)
        password = body().get('password')
        if not isinstance(password, str) or len(password) > 1000 or not check_password_hash(app.config['ADMIN_PASSWORD_HASH'], password):
            database.auth_limited(identity, failure=True)
            raise Problem('unauthorized', '后台密码不正确', 401)
        database.auth_limited(identity, clear=True)
        session.clear()
        session.update(admin=True, csrf_token=secrets.token_urlsafe(32))
        session.permanent = True
        return ok(authenticated=True, csrf_token=session['csrf_token'])

    @app.post('/admin/logout')
    @admin
    def logout():
        session.clear()
        return ok()

    @app.get('/admin/api/state')
    @admin
    def state():
        with database.connect() as db:
            providers = db.execute('SELECT id,name,base_url,enabled,updated_at,(key_enc IS NOT NULL) AS has_key FROM providers ORDER BY name').fetchall()
            models = db.execute('''SELECT m.id,m.name,m.provider_id,m.upstream_model,m.api_mode,m.enabled,m.revision,m.billing_mode,
                m.input_price_per_million,m.output_price_per_million,m.max_input_tokens,m.max_output_tokens,
                m.status,m.last_test_at,m.last_test_error,p.name AS provider_name,p.base_url,
                (p.key_enc IS NOT NULL) AS has_key FROM models m JOIN providers p ON p.id=m.provider_id ORDER BY m.name''').fetchall()
            apps = db.execute('''SELECT a.id,a.name,a.key_prefix,a.enabled,a.model_id,a.monthly_budget_usd,
                a.min_interval_seconds,a.capabilities,a.created_at,
                coalesce(sum(t.charged_usd) FILTER (WHERE t.completed_at>=date_trunc('month',now())),0) AS spent_usd,
                coalesce(sum(t.reserved_usd),0) AS reserved_usd,
                coalesce(sum(t.input_tokens) FILTER (WHERE t.completed_at>=date_trunc('month',now())),0) AS input_tokens,
                coalesce(sum(t.output_tokens) FILTER (WHERE t.completed_at>=date_trunc('month',now())),0) AS output_tokens
                FROM apps a LEFT JOIN tasks t ON t.app_id=a.id GROUP BY a.id ORDER BY a.created_at''').fetchall()
            workers = db.execute('SELECT id,name,key_prefix,enabled,app_ids,last_seen_at,ready,model_configured,agent_version,capabilities FROM workers ORDER BY name').fetchall()
            tasks = db.execute('''SELECT id,app_id,capability,executor,model_id,status,error_code,created_at,completed_at,
                charged_usd,reserved_usd,input_tokens,output_tokens,usage_estimated,billing_mode FROM tasks ORDER BY created_at DESC LIMIT 100''').fetchall()
            tests = db.execute('SELECT * FROM model_tests ORDER BY created_at DESC LIMIT 30').fetchall()
        for model in models:
            model['assigned_apps'] = [str(a['id']) for a in apps if a['model_id'] == model['id']]
            model['usage_only'] = model['billing_mode'] == 'subscription'
            model['pricing_configured'] = model['usage_only'] or (model['input_price_per_million'] is not None and model['output_price_per_million'] is not None)
        for application in apps:
            assigned = next((m for m in models if m['id'] == application['model_id']), None)
            application['billing_mode'] = assigned['billing_mode'] if assigned else None
            application['usage_only'] = application['billing_mode'] == 'subscription'
        for task in tasks:
            task['error'] = {'code': task['error_code'], 'message': MESSAGES.get(task['error_code'], '任务失败')} if task['error_code'] else None
            task['usage_only'] = task['billing_mode'] == 'subscription'
        usage = {key: sum(a[key] for a in apps) for key in ('spent_usd', 'reserved_usd', 'input_tokens', 'output_tokens')}
        return ok(providers=providers, models=models, apps=apps, workers=workers, tasks=tasks, model_tests=tests,
                  usage=usage, capabilities=['music.recommend.v1', 'hermes.analyze.v1'])

    @app.route('/admin/api/providers', methods=['POST'])
    @app.route('/admin/api/providers/<provider_id>', methods=['PATCH'])
    @admin
    def save_provider(provider_id=None):
        data = body()
        with database.connect() as db:
            old = db.execute('SELECT * FROM providers WHERE id=%s FOR UPDATE', (uid(provider_id),)).fetchone() if provider_id else None
            if provider_id and not old:
                raise Problem('not_found', '服务商不存在', 404)
            values = dict(old or {})
            values.update({k: v for k, v in data.items() if k in ('name', 'base_url', 'enabled')})
            name = text(values.get('name'), '服务商名称', 100)
            base_url = validate_base_url(values.get('base_url'))
            enabled = bool_value(values.get('enabled', True))
            key_enc = values.get('key_enc')
            if data.get('api_key'):
                key = text(data['api_key'], 'API Key', 2000)
                key_enc = cipher.encrypt(key.encode()).decode()
            if data.get('clear_key') is True:
                key_enc = None
            row_id = uuid.UUID(provider_id) if provider_id else uuid.uuid4()
            db.execute('''INSERT INTO providers(id,name,base_url,key_enc,enabled) VALUES(%s,%s,%s,%s,%s)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,base_url=excluded.base_url,key_enc=excluded.key_enc,
                enabled=excluded.enabled,updated_at=now()''', (row_id, name, base_url, key_enc, enabled))
            if old:
                db.execute("UPDATE models SET revision=revision+1,status='untested',updated_at=now() WHERE provider_id=%s", (row_id,))
        return ok(provider={'id': row_id, 'name': name, 'base_url': base_url, 'has_key': bool(key_enc), 'enabled': enabled})

    @app.get('/admin/api/providers/<provider_id>/models')
    @admin
    def provider_models(provider_id):
        with database.connect() as db:
            provider = db.execute('SELECT * FROM providers WHERE id=%s', (uid(provider_id),)).fetchone()
        if not provider:
            raise Problem('not_found', '服务商不存在', 404)
        return ok(models=app.extensions['model_proxy'].discover(provider))

    @app.route('/admin/api/models', methods=['POST'])
    @app.route('/admin/api/models/<model_id>', methods=['PATCH'])
    @admin
    def save_model(model_id=None):
        data = body()
        with database.connect() as db:
            old = db.execute('SELECT * FROM models WHERE id=%s FOR UPDATE', (uid(model_id),)).fetchone() if model_id else None
            if model_id and not old:
                raise Problem('not_found', '模型不存在', 404)
            values = {**(old or {}), **data}
            provider_id = uid(values.get('provider_id'))
            if not db.execute('SELECT id FROM providers WHERE id=%s', (provider_id,)).fetchone():
                raise Problem('not_found', '服务商不存在', 404)
            name = text(values.get('name'), '模型显示名称', 100)
            upstream = text(values.get('upstream_model'), '服务商模型名', 200)
            mode = values.get('api_mode', 'responses')
            if mode not in ('responses', 'chat'):
                raise Problem('invalid_input', '请选择 Responses 或 Chat 协议')
            enabled = bool_value(values.get('enabled', True))
            billing_mode = values.get('billing_mode', 'metered')
            if billing_mode not in ('metered', 'subscription'):
                raise Problem('invalid_input', '计费方式无效')
            if billing_mode == 'subscription':
                in_price = out_price = Decimal(0)
            else:
                if old and old.get('billing_mode') == 'subscription':
                    # Subscription's accounting zeros are not evidence of metered prices.
                    for field in ('input_price_per_million', 'output_price_per_million'):
                        if field not in data:
                            values[field] = None
                in_price = price(values.get('input_price_per_million'), '输入价格')
                out_price = price(values.get('output_price_per_million'), '输出价格')
            in_max = integer(values.get('max_input_tokens', 32000), '输入上限', 1024, 64000)
            out_max = integer(values.get('max_output_tokens', 4096), '输出上限', 128, 8000)
            row_id = uuid.UUID(model_id) if model_id else uuid.uuid4()
            db.execute('''INSERT INTO models(id,name,provider_id,upstream_model,api_mode,enabled,input_price_per_million,
                output_price_per_million,max_input_tokens,max_output_tokens,billing_mode) VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,provider_id=excluded.provider_id,
                upstream_model=excluded.upstream_model,api_mode=excluded.api_mode,enabled=excluded.enabled,
                input_price_per_million=excluded.input_price_per_million,output_price_per_million=excluded.output_price_per_million,
                max_input_tokens=excluded.max_input_tokens,max_output_tokens=excluded.max_output_tokens,
                billing_mode=excluded.billing_mode,
                revision=models.revision+1,status='untested',last_test_error=NULL,updated_at=now()''',
                (row_id, name, provider_id, upstream, mode, enabled, in_price, out_price, in_max, out_max, billing_mode))
        return ok(model={'id': row_id, 'name': name, 'status': 'untested'})

    @app.post('/admin/api/models/<model_id>/test')
    @admin
    def test_model(model_id):
        model_id = uid(model_id)
        if body().get('confirm_cost') is not True:
            raise Problem('cost_confirmation_required', '连接测试会发送一条真实模型请求并可能计费')
        if database.auth_limited('test:' + model_id, failure=True):
            raise Problem('rate_limited', '测试过于频繁，请稍后再试', 429)
        with database.connect() as db:
            model = database.model(db, model_id)
        if not model:
            raise Problem('not_found', '模型不存在', 404)
        usage, error, amount = None, None, None
        try:
            route = app.extensions['model_proxy']
            route.sync(model)
            content, usage = route.invoke(model, 'Return a JSON object only.', 'Return {"ok":true}.', output_tokens=128)
            if json.loads(content) != {'ok': True}:
                fail('invalid_model_result', 502)
        except Problem as exc:
            error = exc.code
        except Exception:
            error = 'invalid_model_result'
        usage = usage if isinstance(usage, dict) else {}
        in_tokens, out_tokens = usage.get('input_tokens'), usage.get('output_tokens')
        if not isinstance(in_tokens, int) or isinstance(in_tokens, bool) or in_tokens < 0:
            in_tokens = None
        if not isinstance(out_tokens, int) or isinstance(out_tokens, bool) or out_tokens < 0:
            out_tokens = None
        if model['billing_mode'] != 'subscription' and in_tokens is not None and out_tokens is not None and model['input_price_per_million'] is not None and model['output_price_per_million'] is not None:
            amount = cost(in_tokens, out_tokens, model['input_price_per_million'], model['output_price_per_million'])
        with database.connect() as db:
            db.execute('UPDATE models SET status=%s,last_test_at=now(),last_test_error=%s WHERE id=%s AND revision=%s',
                       ('error' if error else 'ready', error, model_id, model['revision']))
            db.execute('''INSERT INTO model_tests(id,model_id,success,error_code,input_tokens,output_tokens,estimated_usd)
                VALUES(%s,%s,%s,%s,%s,%s,%s)''', (uuid.uuid4(), model_id, not error, error, in_tokens, out_tokens, amount))
        return ok(test={'success': not error, 'error': {'code': error, 'message': MESSAGES.get(error, '测试失败')} if error else None,
                        'input_tokens': in_tokens, 'output_tokens': out_tokens, 'estimated_usd': amount,
                        'cost_known': amount is not None, 'billing_mode': model['billing_mode'],
                        'usage_only': model['billing_mode'] == 'subscription'})

    @app.route('/admin/api/apps', methods=['POST'])
    @app.route('/admin/api/apps/<app_id>', methods=['PATCH'])
    @admin
    def save_app(app_id=None):
        data = body()
        with database.connect() as db:
            old = db.execute('SELECT * FROM apps WHERE id=%s FOR UPDATE', (uid(app_id),)).fetchone() if app_id else None
            if app_id and not old:
                raise Problem('not_found', '软件不存在', 404)
            values = {**(old or {}), **data}
            name = text(values.get('name'), '软件名称', 100)
            enabled = bool_value(values.get('enabled', True))
            budget = price(values.get('monthly_budget_usd', 5), '每月预算', nullable=False)
            interval = integer(values.get('min_interval_seconds', 300), '最小更新间隔', 60, 86400)
            model_id = uid(values['model_id']) if values.get('model_id') else None
            if model_id and not db.execute('SELECT id FROM models WHERE id=%s', (model_id,)).fetchone():
                raise Problem('not_found', '模型不存在', 404)
            caps = values.get('capabilities', ['music.recommend.v1'])
            if not isinstance(caps, list) or not caps or any(c not in ('music.recommend.v1', 'hermes.analyze.v1') for c in caps):
                raise Problem('invalid_input', '能力配置无效')
            key, digest, prefix = new_key('ah_app_') if not old else (None, old['key_hash'], old['key_prefix'])
            row_id = uuid.UUID(app_id) if app_id else uuid.uuid4()
            db.execute('''INSERT INTO apps(id,name,key_hash,key_prefix,enabled,model_id,monthly_budget_usd,min_interval_seconds,capabilities)
                VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT(id) DO UPDATE SET name=excluded.name,enabled=excluded.enabled,
                model_id=excluded.model_id,monthly_budget_usd=excluded.monthly_budget_usd,
                min_interval_seconds=excluded.min_interval_seconds,capabilities=excluded.capabilities,updated_at=now()''',
                (row_id, name, digest, prefix, enabled, model_id, budget, interval, Jsonb(caps)))
        return ok(app={'id': row_id, 'name': name, 'key_prefix': prefix}, **({'api_key': key} if key else {}))

    @app.post('/admin/api/apps/<app_id>/rotate-key')
    @admin
    def rotate_app(app_id):
        key, digest, prefix = new_key('ah_app_')
        with database.connect() as db:
            row = db.execute('UPDATE apps SET key_hash=%s,key_prefix=%s,updated_at=now() WHERE id=%s RETURNING id',
                             (digest, prefix, uid(app_id))).fetchone()
            if not row:
                raise Problem('not_found', '软件不存在', 404)
        return ok(api_key=key, key_prefix=prefix)

    @app.route('/admin/api/workers', methods=['POST'])
    @app.route('/admin/api/workers/<worker_id>', methods=['PATCH'])
    @admin
    def save_worker(worker_id=None):
        data = body()
        with database.connect() as db:
            old = db.execute('SELECT * FROM workers WHERE id=%s', (uid(worker_id),)).fetchone() if worker_id else None
            if worker_id and not old:
                raise Problem('not_found', '节点不存在', 404)
            values = {**(old or {}), **data}
            name = text(values.get('name'), '节点名称', 100)
            enabled = bool_value(values.get('enabled', True))
            app_ids = values.get('app_ids', [])
            if not isinstance(app_ids, list) or len(app_ids) > 100:
                raise Problem('invalid_input', '节点授权的软件列表无效')
            app_ids = [uid(v) for v in app_ids]
            for value in app_ids:
                if not db.execute('SELECT id FROM apps WHERE id=%s', (value,)).fetchone():
                    raise Problem('not_found', '授权软件不存在', 404)
            key, digest, prefix = new_key('ah_worker_') if not old else (None, old['key_hash'], old['key_prefix'])
            row_id = uuid.UUID(worker_id) if worker_id else uuid.uuid4()
            db.execute('''INSERT INTO workers(id,name,key_hash,key_prefix,enabled,app_ids) VALUES(%s,%s,%s,%s,%s,%s)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,enabled=excluded.enabled,app_ids=excluded.app_ids''',
                (row_id, name, digest, prefix, enabled, Jsonb(app_ids)))
        return ok(worker={'id': row_id, 'name': name}, **({'api_key': key} if key else {}))

    def public_task(row, cached=False):
        return {'id': row['id'], 'status': row['status'], 'capability': row['capability'], 'result': row['result'],
                'error': {'code': row['error_code'], 'message': MESSAGES.get(row['error_code'], '任务失败')} if row['error_code'] else None,
                'created_at': row['created_at'], 'completed_at': row['completed_at'],
                'cancel_requested': row['cancel_requested'], 'cached': cached}

    @app.get('/v1/config')
    @bearer('app')
    def app_config():
        application = g.principal
        with database.connect() as db:
            model = database.model(db, application['model_id']) if application['model_id'] else None
        enabled = bool(application['enabled'] and model and model['enabled'] and model['provider_enabled']
                       and model['key_enc'] and (model['billing_mode'] == 'subscription'
                       or (model['input_price_per_million'] is not None and model['output_price_per_million'] is not None)))
        parts = (application['id'], application['updated_at'], model['id'] if model else '',
                 model['revision'] if model else '', model['provider_updated_at'] if model else '', enabled)
        revision = hashlib.sha256('|'.join(str(part) for part in parts).encode()).hexdigest()
        return ok(config={'revision': revision, 'enabled': enabled, 'min_interval_seconds': application['min_interval_seconds']})

    @app.post('/v1/tasks')
    @bearer('app')
    def submit():
        data = body()
        if set(data) - {'subject', 'capability', 'input', 'idempotency_key'}:
            raise Problem('invalid_input', '请求包含未授权字段')
        subject = identifier(data.get('subject'))
        capability = text(data.get('capability'), 'capability', 100)
        idempotency = identifier(data['idempotency_key'], 'idempotency_key') if data.get('idempotency_key') else None
        task, cached = database.submit(g.principal['id'], subject, capability, data.get('input'), idempotency)
        return ok(task=public_task(task, cached)), (200 if cached else 202)

    @app.get('/v1/tasks/<task_id>')
    @bearer('app')
    def get_task(task_id):
        return ok(task=public_task(database.task(g.principal['id'], identifier(request.args.get('subject')), uid(task_id))))

    @app.post('/v1/tasks/<task_id>/cancel')
    @bearer('app')
    def cancel_task(task_id):
        return ok(task=public_task(database.cancel(g.principal['id'], identifier(body().get('subject')), uid(task_id))))

    @app.post('/v1/worker/claim')
    @bearer('worker')
    def worker_claim():
        worker = g.principal
        with database.connect() as db:
            db.execute('UPDATE workers SET last_seen_at=now() WHERE id=%s', (worker['id'],))
        if not worker['ready'] or not worker['model_configured']:
            return ok(task=None, retry_after_seconds=30, status='unconfigured')
        task = database.claim(str(worker['id']), executor='hermes', app_ids=worker['app_ids'])
        if not task:
            return ok(task=None, retry_after_seconds=10)
        public = {k: task[k] for k in ('id', 'app_id', 'subject', 'capability', 'input', 'lease_token', 'max_output_tokens')}
        public.update(model_base_url=app.config['PUBLIC_ORIGIN'] + '/v1/worker/tasks/' + str(task['id']),
                      model_api_key=task['lease_token'], model='assigned-model')
        return ok(task=public,
                  lease_seconds=120)

    @app.post('/v1/worker/status')
    @bearer('worker')
    def worker_status():
        data = body()
        ready = bool_value(data.get('ready', False), 'ready')
        configured = bool_value(data.get('model_configured', False), 'model_configured')
        version = text(data.get('agent_version', 'unknown'), 'agent_version', 80)
        capabilities = data.get('capabilities', [])
        if not isinstance(capabilities, list) or any(c != 'hermes.analyze.v1' for c in capabilities):
            raise Problem('invalid_input', '节点能力无效')
        with database.connect() as db:
            db.execute('''UPDATE workers SET last_seen_at=now(),ready=%s,model_configured=%s,agent_version=%s,capabilities=%s
                WHERE id=%s''', (ready and configured, configured, version, Jsonb(capabilities), g.principal['id']))
        return ok(enabled=g.principal['enabled'], ready=ready and configured,
                  status='ready' if ready and configured else 'unconfigured', retry_after_seconds=30)

    @app.post('/v1/worker/tasks/<task_id>/chat/completions')
    def worker_model_relay(task_id):
        auth = request.headers.get('Authorization', '')
        if not auth.startswith('Bearer ') or not 20 < len(auth) < 200:
            raise Problem('unauthorized', '任务模型凭据无效', 401)
        token = auth[7:]
        row = database.relay_task(uid(task_id), token)
        data = body()
        if data.get('stream') or data.get('tools') or data.get('functions'):
            raise Problem('unsupported_operation', '家庭分析任务只允许一次非流式文本分析，不开放工具', 400)
        if row['relay_status'] == 'succeeded':
            return jsonify(row['relay_response'])
        if row['relay_status'] is not None:
            raise Problem('already_dispatched', '此任务的模型请求已发出，不允许重复计费', 409)
        with database.connect() as db:
            model = database.model(db, row['model_id'])
        if not model or model['revision'] != row['model_revision']:
            fail('configuration_changed', 409)
        route = app.extensions['model_proxy']
        route.sync(model)
        if not database.relay_begin(row['id'], token):
            raise Problem('already_dispatched', '任务已开始或已取消', 409)
        usage = None
        try:
            # Never let an executor substitute a new system prompt, another subject's input,
            # a model name, URL or tool operation. It executes the submitted capability only.
            system, user = prompt_for(row['capability'], row['input'])
            content, usage = route.invoke(model, system, user, row['max_output_tokens'])
            validate_result(row['capability'], json.loads(content), row['input'])
            response = {'id': 'chatcmpl-hub-' + str(row['id']), 'object': 'chat.completion',
                        'created': int(datetime.now().timestamp()), 'model': 'assigned-model',
                        'choices': [{'index': 0, 'message': {'role': 'assistant', 'content': content}, 'finish_reason': 'stop'}],
                        'usage': {'prompt_tokens': (usage or {}).get('input_tokens', 0),
                                  'completion_tokens': (usage or {}).get('output_tokens', 0)}}
            database.relay_finish(row['id'], token, response=response, usage=usage)
            return jsonify(response)
        except Exception as error:
            database.relay_finish(row['id'], token, usage=usage)
            if isinstance(error, Problem):
                raise
            fail('invalid_model_result', 502)

    def worker_task():
        data = body()
        task_id, token = uid(data.get('task_id')), text(data.get('lease_token'), 'lease_token', 100)
        with database.connect() as db:
            row = db.execute('SELECT * FROM tasks WHERE id=%s', (task_id,)).fetchone()
        if (not row or str(row['app_id']) not in g.principal['app_ids'] or row['executor'] != 'hermes'
                or row['lease_owner'] != str(g.principal['id']) or row['lease_token'] != token):
            raise Problem('lease_lost', '任务租约无效', 409)
        return row, data, token

    @app.post('/v1/worker/start')
    @bearer('worker')
    def worker_start():
        row, data, token = worker_task()
        if not database.start(row['id'], str(g.principal['id']), token):
            try:
                database.finish(row['id'], str(g.principal['id']), token, error='configuration_changed', unstarted=True)
            except Problem:
                pass
            raise Problem('lease_lost', '任务已取消或租约失效', 409)
        return ok()

    @app.post('/v1/worker/heartbeat')
    @bearer('worker')
    def worker_heartbeat():
        row, data, token = worker_task()
        state = database.heartbeat(row['id'], str(g.principal['id']), token)
        if not state:
            raise Problem('lease_lost', '任务租约已失效', 409)
        return ok(cancel_requested=state['cancel_requested'])

    @app.post('/v1/worker/complete')
    @bearer('worker')
    def worker_complete():
        row, data, token = worker_task()
        if row['status'] != 'running':
            raise Problem('lease_lost', '任务尚未开始执行', 409)
        result, error = None, None
        if data.get('error'):
            error = 'worker_failed'
        else:
            try:
                if row['relay_status'] != 'succeeded':
                    raise Problem('model_not_called', '任务尚未完成中央模型调用', 409)
                result = validate_result(row['capability'], data.get('result'), row['input'])
                actual = json.loads(row['relay_response']['choices'][0]['message']['content'])
                if result != actual:
                    raise Problem('invalid_model_result', '节点结果与模型结果不一致', 502)
            except Problem:
                error = 'invalid_model_result'
        database.finish(row['id'], str(g.principal['id']), token, result=result, error=error,
                        unstarted=bool(error and row['relay_status'] is None))
        return ok()

    return app


# Importing the factory is safe in tests; production requires all private environment settings.
app = create_app() if os.getenv('AI_HUB_DATABASE_URL') else None
