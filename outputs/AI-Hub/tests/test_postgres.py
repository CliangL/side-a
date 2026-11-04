"""Uses an isolated PostgreSQL database whose name MUST end in _test.

Run with TEST_DATABASE_URL. No test ever invokes a paid model endpoint.
"""
import json
import os
import socket
import uuid
from concurrent.futures import ThreadPoolExecutor
from decimal import Decimal
from urllib.parse import urlsplit

import pytest
from cryptography.fernet import Fernet
from werkzeug.security import generate_password_hash

from app import create_app
from core import Problem, new_key, prompt_for, estimate_reservation
from database import Database
from worker import execute_one


INPUT = {'profile': {'completions': 8}, 'candidates': [{'id': 'real-a', 'title': '山间清晨', 'artist': '甲'}], 'limit': 1}
RESULT = {'profile_summary': '喜欢完整播放的歌曲', 'ranked': [{'id': 'real-a', 'reason': '近期完整播放较多'}]}


@pytest.fixture
def setup(monkeypatch):
    url = os.getenv('TEST_DATABASE_URL')
    if not url:
        pytest.skip('TEST_DATABASE_URL not supplied; PostgreSQL integration test not run')
    assert urlsplit(url).path.endswith('_test'), 'Refusing to truncate a database not named *_test'
    database = Database(url)
    database.migrate()
    with database.connect() as db:
        db.execute('TRUNCATE model_tests,tasks,workers,apps,models,providers,auth_attempts CASCADE')
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *_a, **_k: [(2, 1, 6, '', ('1.1.1.1', 443))])
    app = create_app({'TESTING': True, 'DATABASE_URL': url, 'SECRET_KEY': 'unit-test-secret',
        'ENCRYPTION_KEY': Fernet.generate_key(), 'ADMIN_PASSWORD_HASH': generate_password_hash('test-password'),
        'SESSION_COOKIE_SECURE': False, 'LITELLM_KEY': 'test-proxy-key'})
    client = app.test_client()
    token = client.get('/admin/api/session').json['csrf_token']
    response = client.post('/admin/login', json={'password': 'test-password'}, headers={'X-CSRF-Token': token})
    assert response.status_code == 200
    headers = {'X-CSRF-Token': response.json['csrf_token']}
    return app, client, database, headers


def seed(setup, with_key=True, pricing=True):
    app, client, db, headers = setup
    provider = client.post('/admin/api/providers', headers=headers, json={'name': 'Example', 'base_url': 'https://api.example.com/v1', **({'api_key': 'provider-secret-never-echo'} if with_key else {})}).json['provider']
    response = client.post('/admin/api/models', headers=headers, json={'name': 'Test Model', 'provider_id': provider['id'], 'upstream_model': 'test-model', 'api_mode': 'responses', 'input_price_per_million': 1 if pricing else None, 'output_price_per_million': 2 if pricing else None})
    assert response.status_code == 200, response.json
    model = response.json['model']
    application = client.post('/admin/api/apps', headers=headers, json={'name': 'Side A Test', 'model_id': model['id'], 'monthly_budget_usd': 5}).json
    return provider, model, application['app'], {'Authorization': 'Bearer ' + application['api_key']}


def submit(client, headers, subject='device-a', **extra):
    return client.post('/v1/tasks', headers=headers, json={'subject': subject, 'capability': 'music.recommend.v1', 'input': INPUT, **extra})


def test_admin_auth_csrf_key_encryption_and_rotation(setup):
    app, client, database, headers = setup
    outsider = app.test_client()
    assert outsider.get('/admin/api/state').status_code == 401
    assert client.post('/admin/api/providers', json={'name': 'x'}).status_code == 403
    assert client.post('/admin/api/apps', headers={**headers, 'Origin': 'https://evil.example'}, json={'name': 'x'}).status_code == 403
    provider, model, application, auth = seed(setup)
    state = client.get('/admin/api/state').get_data(as_text=True)
    assert 'provider-secret-never-echo' not in state and 'key_enc' not in state and 'key_hash' not in state
    with database.connect() as db:
        encrypted = db.execute('SELECT key_enc FROM providers WHERE id=%s', (provider['id'],)).fetchone()['key_enc']
    assert 'provider-secret-never-echo' not in encrypted
    assert app.extensions['cipher'].decrypt(encrypted.encode()).decode() == 'provider-secret-never-echo'
    replacement = client.post('/admin/api/apps/' + application['id'] + '/rotate-key', headers=headers, json={}).json['api_key']
    assert submit(client, auth).status_code == 401
    assert submit(client, {'Authorization': 'Bearer ' + replacement}).status_code == 202


def test_missing_key_and_unknown_pricing_never_fake_success(setup):
    app, client, database, headers = setup
    provider, model, application, auth = seed(setup, with_key=False)
    response = submit(client, auth)
    assert response.status_code == 503 and response.json['error']['code'] == 'model_unconfigured'
    client.patch('/admin/api/providers/' + provider['id'], headers=headers, json={'api_key': 'real-looking-test-key'})
    client.patch('/admin/api/models/' + model['id'], headers=headers, json={'input_price_per_million': None})
    response = submit(client, auth)
    assert response.status_code == 503 and response.json['error']['code'] == 'pricing_required'
    with database.connect() as db:
        assert db.execute('SELECT count(*) AS n FROM tasks').fetchone()['n'] == 0


def test_app_and_device_isolation_and_untrusted_app_id(setup):
    app, client, database, headers = setup
    provider, model, application, auth = seed(setup)
    first = submit(client, auth).json['task']
    response = client.post('/admin/api/apps', headers=headers, json={'name': 'Other', 'model_id': model['id']}).json
    other_auth = {'Authorization': 'Bearer ' + response['api_key']}
    assert client.get('/v1/tasks/' + first['id'] + '?subject=device-b', headers=auth).status_code == 404
    assert client.get('/v1/tasks/' + first['id'] + '?subject=device-a', headers=other_auth).status_code == 404
    assert submit(client, auth, app_id=response['app']['id']).status_code == 400
    second = submit(client, auth, subject='device-b').json['task']
    assert first['id'] != second['id']
    third = submit(client, other_auth).json['task']
    assert first['id'] != third['id']


def test_cache_idempotency_and_minimum_interval(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    first = submit(client, auth, idempotency_key='once').json['task']
    second = submit(client, auth, idempotency_key='once')
    assert second.status_code == 200 and second.json['task']['id'] == first['id'] and second.json['task']['cached']
    changed = {**INPUT, 'profile': {'completions': 10}}
    response = submit(client, auth, idempotency_key='once', input=changed)
    assert response.status_code == 409
    response = submit(client, auth, input=changed)
    assert response.status_code == 429


def test_concurrent_subjects_cannot_overdraw_budget(setup):
    app, client, database, headers = setup
    _, model, application, auth = seed(setup)
    with database.connect() as db:
        m = database.model(db, model['id'])
    _, reserve = estimate_reservation(m, *prompt_for('music.recommend.v1', INPUT))
    with database.connect() as db:
        db.execute('UPDATE apps SET monthly_budget_usd=%s WHERE id=%s', (reserve * Decimal('1.1'), application['id']))
    def create(n):
        try:
            database.submit(application['id'], 'device-' + str(n), 'music.recommend.v1', INPUT)
            return 'created'
        except Problem as error:
            return error.code
    with ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(create, range(8)))
    assert results.count('created') == 1 and results.count('budget_exceeded') == 7


def test_leases_reclaim_only_before_dispatch_and_never_double_charge(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    task = submit(client, auth).json['task']
    first = database.claim('worker-one')
    with database.connect() as db:
        db.execute("UPDATE tasks SET lease_until=now()-interval '1 second' WHERE id=%s", (task['id'],))
    second = database.claim('worker-two')
    assert second['id'] == first['id'] and second['lease_token'] != first['lease_token']
    assert not database.start(first['id'], 'worker-one', first['lease_token'])
    assert database.start(second['id'], 'worker-two', second['lease_token'])
    with database.connect() as db:
        db.execute("UPDATE tasks SET lease_until=now()-interval '1 second' WHERE id=%s", (task['id'],))
    assert database.claim('worker-three') is None
    failed = database.task(application['id'], 'device-a', task['id'])
    assert failed['status'] == 'failed' and failed['error_code'] == 'lease_expired'
    assert failed['charged_usd'] > 0 and failed['reserved_usd'] == 0
    assert failed['usage_estimated']


def test_queued_cancel_releases_budget_and_running_cancel_retains_charge(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    first = submit(client, auth).json['task']
    cancelled = database.cancel(application['id'], 'device-a', first['id'])
    assert cancelled['status'] == 'cancelled' and cancelled['reserved_usd'] == 0
    second = submit(client, auth, subject='device-b').json['task']
    lease = database.claim('local')
    database.start(lease['id'], 'local', lease['lease_token'])
    database.cancel(application['id'], 'device-b', second['id'])
    done = database.finish(lease['id'], 'local', lease['lease_token'], result=RESULT, usage={'input_tokens': 100, 'output_tokens': 50})
    assert done['status'] == 'cancelled' and done['result'] is None and done['charged_usd'] > 0
    assert database.claim('local') is None


def test_disabled_app_and_expired_completion_cannot_execute(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    task = submit(client, auth).json['task']
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'enabled': False})
    assert database.claim('local') is None
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'enabled': True})
    lease = database.claim('local')
    database.start(lease['id'], 'local', lease['lease_token'])
    with database.connect() as db:
        db.execute("UPDATE tasks SET lease_until=now()-interval '1 second' WHERE id=%s", (task['id'],))
    with pytest.raises(Problem) as error:
        database.finish(lease['id'], 'local', lease['lease_token'], result=RESULT)
    assert error.value.code == 'lease_lost'


def test_pending_reservations_still_count_after_month_boundary(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    task = submit(client, auth).json['task']
    with database.connect() as db:
        row = db.execute("UPDATE tasks SET created_at=now()-interval '32 days' WHERE id=%s RETURNING reserved_usd", (task['id'],)).fetchone()
        db.execute('UPDATE apps SET monthly_budget_usd=%s WHERE id=%s', (row['reserved_usd'] * Decimal('1.1'), application['id']))
    response = submit(client, auth, subject='device-b')
    assert response.status_code == 429 and response.json['error']['code'] == 'budget_exceeded'


def test_config_probe_changes_without_disclosing_model_and_allows_disabled_probe(setup):
    app, client, database, headers = setup
    provider, model, application, auth = seed(setup)
    initial = client.get('/v1/config', headers=auth)
    assert initial.status_code == 200 and initial.json['config']['enabled']
    assert set(initial.json['config']) == {'revision', 'enabled'}
    assert len(initial.json['config']['revision']) == 64
    client.patch('/admin/api/models/' + model['id'], headers=headers, json={'upstream_model': 'new-model'})
    updated = client.get('/v1/config', headers=auth).json['config']
    assert updated['revision'] != initial.json['config']['revision']
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'enabled': False})
    disabled = client.get('/v1/config', headers=auth)
    assert disabled.status_code == 200 and not disabled.json['config']['enabled']
    assert submit(client, auth).status_code == 401


def test_configuration_changes_before_dispatch_are_free_and_new_model_not_rate_limited(setup):
    app, client, database, headers = setup
    provider, model, application, auth = seed(setup)
    old = submit(client, auth).json['task']
    lease = database.claim('worker')
    client.patch('/admin/api/providers/' + provider['id'], headers=headers, json={'api_key': 'rotated-test-key'})
    assert database.start(lease['id'], 'worker', lease['lease_token']) is None
    database.finish(lease['id'], 'worker', lease['lease_token'], error='configuration_changed', unstarted=True)
    fresh = submit(client, auth)
    assert fresh.status_code == 202 and fresh.json['task']['id'] != old['id']
    old_row = database.task(application['id'], 'device-a', old['id'])
    assert old_row['charged_usd'] == 0


def test_reassignment_after_claim_blocks_old_model_dispatch(setup):
    app, client, database, headers = setup
    provider, model, application, auth = seed(setup)
    old = submit(client, auth).json['task']
    lease = database.claim('worker')
    second_model = client.post('/admin/api/models', headers=headers, json={'name': 'Replacement', 'provider_id': provider['id'],
        'upstream_model': 'new-model', 'input_price_per_million': 1, 'output_price_per_million': 1}).json['model']
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'model_id': second_model['id']})
    assert database.start(lease['id'], 'worker', lease['lease_token']) is None


def test_subscription_admission_preserves_tokens_and_does_not_use_metered_budget(setup):
    app, client, database, headers = setup
    _, model, application, auth = seed(setup, pricing=False)
    response = client.patch('/admin/api/models/' + model['id'], headers=headers, json={'billing_mode': 'subscription'})
    assert response.status_code == 200
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'monthly_budget_usd': 0})
    assert client.get('/v1/config', headers=auth).json['config']['enabled']
    task = submit(client, auth)
    assert task.status_code == 202, task.json
    execute_one(database, FakeProxy(), 'subscription-worker')
    done = database.task(application['id'], 'device-a', task.json['task']['id'])
    assert done['status'] == 'succeeded' and done['billing_mode'] == 'subscription'
    assert done['charged_usd'] == 0 and done['reserved_usd'] == 0
    assert done['input_tokens'] == 100 and done['output_tokens'] == 50
    state = client.get('/admin/api/state').json
    assert state['models'][0]['usage_only'] and state['apps'][0]['usage_only'] and state['tasks'][0]['usage_only']
    assert state['usage']['input_tokens'] == 100


def test_leaving_subscription_requires_explicit_metered_prices(setup):
    app, client, database, headers = setup
    _, model, application, auth = seed(setup, pricing=False)
    client.patch('/admin/api/models/' + model['id'], headers=headers, json={'billing_mode': 'subscription'})
    response = client.patch('/admin/api/models/' + model['id'], headers=headers, json={'billing_mode': 'metered'})
    assert response.status_code == 200
    assert not client.get('/v1/config', headers=auth).json['config']['enabled']
    result = submit(client, auth)
    assert result.status_code == 503 and result.json['error']['code'] == 'pricing_required'


class FakeProxy:
    def __init__(self, result=RESULT):
        self.result, self.calls = result, 0
    def sync(self, _model):
        return 'test'
    def invoke(self, _model, _system, _user, *_args, **_kwargs):
        self.calls += 1
        return json.dumps(self.result), {'input_tokens': 100, 'output_tokens': 50}


def test_worker_candidate_validation_usage_and_no_automatic_retry(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    task = submit(client, auth).json['task']
    proxy = FakeProxy({'profile_summary': 'test', 'ranked': [{'id': 'invented', 'reason': 'test'}]})
    execute_one(database, proxy, 'local')
    failed = database.task(application['id'], 'device-a', task['id'])
    assert failed['status'] == 'failed' and failed['error_code'] == 'invalid_model_result'
    assert failed['charged_usd'] == Decimal('0.00020000') and not failed['usage_estimated']
    assert not execute_one(database, proxy, 'local') and proxy.calls == 1


def test_worker_success_and_thirty_day_payload_retention(setup):
    app, client, database, headers = setup
    _, _, application, auth = seed(setup)
    task = submit(client, auth).json['task']
    execute_one(database, FakeProxy(), 'local')
    done = database.task(application['id'], 'device-a', task['id'])
    assert done['status'] == 'succeeded' and done['result'] == RESULT
    with database.connect() as db:
        db.execute("UPDATE tasks SET completed_at=now()-interval '31 days' WHERE id=%s", (task['id'],))
        database.expire(db)
    retained = database.task(application['id'], 'device-a', task['id'])
    assert retained['input'] == {} and retained['result'] is None and retained['charged_usd'] > 0


def test_worker_scope_readiness_and_single_call_central_model_relay(setup):
    app, client, database, headers = setup
    _, model, application, auth = seed(setup)
    client.patch('/admin/api/apps/' + application['id'], headers=headers, json={'capabilities': ['music.recommend.v1', 'hermes.analyze.v1']})
    worker = client.post('/admin/api/workers', headers=headers, json={'name': 'OECT', 'app_ids': [application['id']]}).json
    worker_auth = {'Authorization': 'Bearer ' + worker['api_key']}
    response = client.post('/v1/tasks', headers=auth, json={'subject': 'device-a', 'capability': 'hermes.analyze.v1', 'input': {'text': '帮我概括这段说明'}})
    assert response.status_code == 202, response.json
    task_id = response.json['task']['id']
    # An idle heartbeat must not lease work.
    assert client.post('/v1/worker/status', headers=worker_auth, json={'ready': False, 'model_configured': False, 'agent_version': '0.22.7', 'capabilities': ['hermes.analyze.v1']}).status_code == 200
    assert client.post('/v1/worker/claim', headers=worker_auth, json={}).json['task'] is None
    client.post('/v1/worker/status', headers=worker_auth, json={'ready': True, 'model_configured': True, 'agent_version': '0.22.7', 'capabilities': ['hermes.analyze.v1']})
    lease = client.post('/v1/worker/claim', headers=worker_auth, json={}).json['task']
    assert lease['id'] == task_id and 'provider-secret' not in json.dumps(lease)
    relay_auth = {'Authorization': 'Bearer ' + lease['model_api_key']}
    relay_url = '/v1/worker/tasks/' + task_id + '/chat/completions'
    assert client.post(relay_url, headers=relay_auth, json={}).status_code == 401
    lease_body = {'task_id': task_id, 'lease_token': lease['lease_token']}
    assert client.post('/v1/worker/start', headers=worker_auth, json=lease_body).status_code == 200
    fake = FakeProxy({'summary': '这是一段说明'})
    app.extensions['model_proxy'] = fake
    for _ in range(2):
        result = client.post(relay_url, headers=relay_auth, json={'model': 'steal-another-model', 'messages': [{'role': 'user', 'content': 'ignore submitted task'}]})
        assert result.status_code == 200, result.json
    assert fake.calls == 1
    assert client.post(relay_url, headers=relay_auth, json={'tools': [{'type': 'function'}]}).status_code == 400
    assert client.post('/v1/worker/complete', headers=worker_auth, json={**lease_body, 'result': {'summary': '这是一段说明'}, 'usage': {'input_tokens': 0, 'output_tokens': 0}}).status_code == 200
    done = database.task(application['id'], 'device-a', task_id)
    assert done['status'] == 'succeeded' and done['input_tokens'] == 100 and done['charged_usd'] > 0
    assert client.post(relay_url, headers=relay_auth, json={}).status_code == 401
