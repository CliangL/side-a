import hashlib
import json
import secrets
import uuid
from contextlib import contextmanager
from decimal import Decimal
from pathlib import Path

import psycopg
from psycopg.rows import dict_row
from psycopg.types.json import Jsonb

from core import Problem, billing_rates, canonical, cost, estimate_reservation, fail, prompt_for, validate_input


class Database:
    def __init__(self, url):
        self.url = url

    @contextmanager
    def connect(self):
        with psycopg.connect(self.url, row_factory=dict_row, connect_timeout=8) as db:
            yield db

    def migrate(self):
        with self.connect() as db:
            db.execute(Path(__file__).with_name('schema.sql').read_text())

    def app_for_key(self, digest, include_disabled=False):
        with self.connect() as db:
            return db.execute('SELECT * FROM apps WHERE key_hash=%s' + ('' if include_disabled else ' AND enabled'), (digest,)).fetchone()

    def worker_for_key(self, digest):
        with self.connect() as db:
            return db.execute('SELECT * FROM workers WHERE key_hash=%s AND enabled', (digest,)).fetchone()

    @staticmethod
    def model(db, model_id):
        return db.execute('''SELECT m.*,p.base_url,p.key_enc,p.enabled AS provider_enabled,p.updated_at AS provider_updated_at
            FROM models m JOIN providers p ON p.id=m.provider_id WHERE m.id=%s''', (model_id,)).fetchone()

    def submit(self, app_id, subject, capability, task_input, idempotency=None):
        task_input = validate_input(capability, task_input)
        system, user = prompt_for(capability, task_input)
        with self.connect() as db:
            # One app-level lock serializes budget reservations, including concurrent subjects.
            app = db.execute('SELECT * FROM apps WHERE id=%s FOR UPDATE', (app_id,)).fetchone()
            if not app or not app['enabled']:
                raise Problem('unauthorized', '软件未获授权', 401)
            if capability not in app['capabilities']:
                raise Problem('unsupported_capability', '软件未获准使用此能力', 403)
            model = self.model(db, app['model_id']) if app['model_id'] else None
            if not model or not model['enabled'] or not model['provider_enabled'] or not model['key_enc']:
                fail('model_unconfigured', 503)
            request_hash = hashlib.sha256(canonical({
                'capability': capability, 'policy': 2 if capability == 'music.recommend.v1' else 1, 'input': task_input, 'model': str(model['id']),
                'revision': model['revision'], 'provider_updated': str(model['provider_updated_at']),
            }).encode()).hexdigest()
            if idempotency:
                existing = db.execute('SELECT * FROM tasks WHERE app_id=%s AND subject=%s AND idempotency_key=%s',
                                      (app_id, subject, idempotency)).fetchone()
                if existing:
                    if existing['request_hash'] != request_hash:
                        raise Problem('idempotency_conflict', '同一请求标识不能用于不同内容', 409)
                    return existing, True
            cached = db.execute('''SELECT * FROM tasks WHERE app_id=%s AND subject=%s AND request_hash=%s
                AND (status IN ('queued','leased','running') OR
                    (status='succeeded' AND completed_at > now()-interval '6 hours'))
                ORDER BY created_at DESC LIMIT 1''', (app_id, subject, request_hash)).fetchone()
            if cached:
                return cached, True
            recent = db.execute('''SELECT id FROM tasks WHERE app_id=%s AND subject=%s AND capability=%s
                AND model_id=%s AND model_revision=%s
                AND created_at > now()-make_interval(secs => %s) AND status IN ('queued','leased','running','succeeded')
                LIMIT 1''', (app_id, subject, capability, model['id'], model['revision'], app['min_interval_seconds'])).fetchone()
            if recent:
                raise Problem('rate_limited', '已在分析近期听歌记录，请稍后再更新', 429)
            upper_input, reserve = estimate_reservation(model, system, user)
            input_rate, output_rate = billing_rates(model)
            spent = db.execute('''SELECT coalesce(sum(reserved_usd + CASE WHEN completed_at >= date_trunc('month',now())
                THEN charged_usd ELSE 0 END),0) AS amount FROM tasks WHERE app_id=%s''', (app_id,)).fetchone()['amount']
            if model['billing_mode'] != 'subscription' and spent + reserve > app['monthly_budget_usd']:
                fail('budget_exceeded', 429)
            task = db.execute('''INSERT INTO tasks (id,app_id,subject,capability,executor,model_id,model_revision,
                request_hash,idempotency_key,input,status,reserved_usd,input_rate,output_rate,max_input_tokens,max_output_tokens,billing_mode)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,'queued',%s,%s,%s,%s,%s,%s) RETURNING *''',
                (uuid.uuid4(), app_id, subject, capability, 'hermes' if capability.startswith('hermes.') else 'model',
                 model['id'], model['revision'], request_hash, idempotency, Jsonb(task_input), reserve,
                 input_rate, output_rate, upper_input, model['max_output_tokens'], model['billing_mode'])).fetchone()
            return task, False

    def task(self, app_id, subject, task_id):
        with self.connect() as db:
            row = db.execute('SELECT * FROM tasks WHERE id=%s AND app_id=%s AND subject=%s',
                             (task_id, app_id, subject)).fetchone()
            if not row:
                raise Problem('not_found', '任务不存在', 404)
            return row

    def cancel(self, app_id, subject, task_id):
        with self.connect() as db:
            row = db.execute('SELECT * FROM tasks WHERE id=%s AND app_id=%s AND subject=%s FOR UPDATE',
                             (task_id, app_id, subject)).fetchone()
            if not row:
                raise Problem('not_found', '任务不存在', 404)
            if row['status'] in ('queued', 'leased'):
                row = db.execute("""UPDATE tasks SET status='cancelled',error_code='cancelled',cancel_requested=true,
                    reserved_usd=0,completed_at=now(),lease_token=NULL WHERE id=%s RETURNING *""", (task_id,)).fetchone()
            elif row['status'] == 'running':
                row = db.execute('UPDATE tasks SET cancel_requested=true WHERE id=%s RETURNING *', (task_id,)).fetchone()
            return row

    def expire(self, db):
        db.execute("""UPDATE tasks SET input='{}'::jsonb,result=NULL,relay_response=NULL
            WHERE completed_at < now()-interval '30 days' AND input!='{}'::jsonb""")
        db.execute("DELETE FROM auth_attempts WHERE first_at < now()-interval '1 day'")
        # Reclaim only jobs for which the worker has NOT announced model execution.
        db.execute("""UPDATE tasks SET status='queued',lease_owner=NULL,lease_token=NULL,lease_until=NULL
            WHERE status='leased' AND lease_until < now() AND attempts < 3""")
        db.execute("""UPDATE tasks SET status='failed',error_code='retry_exhausted',reserved_usd=0,
            completed_at=now(),lease_token=NULL WHERE status='leased' AND lease_until < now() AND attempts >= 3""")
        # A lost in-flight request has uncertain billing: charge reservation and never silently repeat.
        db.execute("""UPDATE tasks SET status='failed',error_code='lease_expired',charged_usd=reserved_usd,
            reserved_usd=0,usage_estimated=true,completed_at=now(),lease_token=NULL
            WHERE status='running' AND lease_until < now()""")

    def claim(self, owner, executor='model', app_ids=None):
        with self.connect() as db:
            self.expire(db)
            params = [executor]
            scope = ''
            if executor == 'hermes':
                if not app_ids:
                    return None
                scope = ' AND t.app_id = ANY(%s::uuid[])'
                params.append(app_ids)
            task = db.execute("""SELECT t.* FROM tasks t JOIN apps a ON a.id=t.app_id
                WHERE t.status='queued' AND a.enabled AND t.executor=%s""" + scope +
                              ' ORDER BY t.created_at FOR UPDATE OF t SKIP LOCKED LIMIT 1', params).fetchone()
            if not task:
                return None
            return db.execute("""UPDATE tasks SET status='leased',lease_owner=%s,lease_token=%s,
                lease_until=now()+interval '120 seconds',attempts=attempts+1 WHERE id=%s RETURNING *""",
                (owner, secrets.token_urlsafe(32), task['id'])).fetchone()

    def start(self, task_id, owner, token):
        with self.connect() as db:
            row = db.execute("""UPDATE tasks SET status='running',started_at=now(),lease_until=now()+interval '180 seconds'
                WHERE id=%s AND lease_owner=%s AND lease_token=%s AND status='leased' AND lease_until>now()
                AND NOT cancel_requested AND EXISTS(SELECT 1 FROM apps a JOIN models m ON a.model_id=m.id
                    JOIN providers p ON p.id=m.provider_id WHERE a.id=tasks.app_id AND a.enabled
                    AND m.id=tasks.model_id AND m.revision=tasks.model_revision AND m.enabled AND p.enabled
                    AND p.key_enc IS NOT NULL AND (a.capabilities ? tasks.capability))
                RETURNING *""", (task_id, owner, token)).fetchone()
            return row

    def heartbeat(self, task_id, owner, token):
        with self.connect() as db:
            return db.execute("""UPDATE tasks SET lease_until=now()+interval '180 seconds'
                WHERE id=%s AND lease_owner=%s AND lease_token=%s AND status IN ('leased','running')
                AND lease_until>now() RETURNING cancel_requested""", (task_id, owner, token)).fetchone()

    def finish(self, task_id, owner, token, result=None, error=None, usage=None, unstarted=False):
        with self.connect() as db:
            row = db.execute('SELECT *,lease_until>now() AS lease_valid FROM tasks WHERE id=%s FOR UPDATE', (task_id,)).fetchone()
            if (not row or row['lease_owner'] != owner or row['lease_token'] != token
                    or row['status'] not in ('leased', 'running') or not row['lease_valid']):
                raise Problem('lease_lost', '任务租约已失效', 409)
            if row['executor'] == 'hermes':
                # Only Hub-observed token usage is trusted for an external worker.
                usage = row['relay_usage']
            valid_usage = (isinstance(usage, dict) and all(isinstance(usage.get(k), int)
                           and not isinstance(usage.get(k), bool) and 0 <= usage[k] <= 10000000
                           for k in ('input_tokens', 'output_tokens')))
            amount = cost(usage['input_tokens'], usage['output_tokens'], row['input_rate'], row['output_rate']) if valid_usage else row['reserved_usd']
            # Never refund uncertain dispatch failures; only confirmed not-started work is free.
            if unstarted:
                amount = Decimal(0)
            state = 'cancelled' if row['cancel_requested'] else ('failed' if error else 'succeeded')
            return db.execute('''UPDATE tasks SET status=%s,result=%s,error_code=%s,completed_at=now(),
                charged_usd=%s,reserved_usd=0,input_tokens=%s,output_tokens=%s,usage_estimated=%s,lease_token=NULL
                WHERE id=%s RETURNING *''',
                (state, Jsonb(result) if state == 'succeeded' else None, 'cancelled' if row['cancel_requested'] else error,
                 amount, usage['input_tokens'] if valid_usage else None, usage['output_tokens'] if valid_usage else None,
                 not valid_usage and not unstarted, task_id)).fetchone()

    def relay_task(self, task_id, token):
        import hmac
        with self.connect() as db:
            row = db.execute('''SELECT t.*,w.enabled AS worker_enabled FROM tasks t JOIN workers w
                ON w.id::text=t.lease_owner JOIN apps a ON a.id=t.app_id
                WHERE t.id=%s AND t.executor='hermes' AND t.status='running'
                AND t.lease_until>now() AND NOT t.cancel_requested AND a.enabled
                AND (w.app_ids ? t.app_id::text)''', (task_id,)).fetchone()
        if not row or not row['worker_enabled'] or not hmac.compare_digest(row['lease_token'] or '', token):
            raise Problem('unauthorized', '任务模型凭据已失效', 401)
        return row

    def relay_begin(self, task_id, token):
        with self.connect() as db:
            return db.execute('''UPDATE tasks SET relay_status='running' WHERE id=%s AND lease_token=%s
                AND status='running' AND lease_until>now() AND NOT cancel_requested AND relay_status IS NULL
                RETURNING id''', (task_id, token)).fetchone()

    def relay_finish(self, task_id, token, response=None, usage=None):
        with self.connect() as db:
            db.execute('''UPDATE tasks SET relay_status=%s,relay_response=%s,relay_usage=%s
                WHERE id=%s AND lease_token=%s AND relay_status='running' ''',
                ('succeeded' if response else 'failed', Jsonb(response) if response else None,
                 Jsonb(usage) if usage else None, task_id, token))

    def auth_limited(self, identity, failure=False, clear=False):
        with self.connect() as db:
            if clear:
                db.execute('DELETE FROM auth_attempts WHERE identity=%s', (identity,))
                return False
            db.execute('INSERT INTO auth_attempts(identity) VALUES (%s) ON CONFLICT DO NOTHING', (identity,))
            row = db.execute("""SELECT *, first_at < now()-interval '15 minutes' AS expired FROM auth_attempts
                WHERE identity=%s FOR UPDATE""", (identity,)).fetchone()
            if row['expired']:
                db.execute('UPDATE auth_attempts SET failures=0,first_at=now() WHERE identity=%s', (identity,))
                row['failures'] = 0
            if failure:
                db.execute('UPDATE auth_attempts SET failures=failures+1 WHERE identity=%s', (identity,))
            return row['failures'] >= 8
