"""Synthetic-only restore, ownership and concurrent-write regression tests."""
import concurrent.futures
import hashlib
import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path

from server import make_app
from test_server import FixtureQQ


class DeviceLibraryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.ticket = 'L' * 43
        manifest = [{'ticket_hash': hashlib.sha256(self.ticket.encode()).hexdigest(), 'device_limit': 8}]
        (self.root / 'private-builds.json').write_text(json.dumps(manifest))
        self.app = make_app(self.root, FixtureQQ())
        self.base = {'base_url': 'https://sidea.test'}
        self.installation = str(uuid.uuid4())
        self.token = self.enroll(self.installation).json['token']

    def tearDown(self):
        self.temp.cleanup()

    def enroll(self, installation=None, recovery=None, platform='ios'):
        body = {'name': '合成测试手机', 'installation': installation or str(uuid.uuid4())}
        if recovery is not None:
            body.update(recovery=recovery, platform=platform)
        return self.app.test_client().post('/v1/enroll', json=body,
            headers={'Authorization': 'SideA-Setup ' + self.ticket}, **self.base)

    def call(self, method, path='/v1/library', token=None, **kwargs):
        return self.app.test_client().open(path, method=method,
            headers={'Authorization': 'Bearer ' + (token or self.token)}, **self.base, **kwargs)

    def bind(self, recovery='1' * 64, token=None, platform='ios'):
        return self.call('POST', '/v1/library/bind', token=token, json={'recovery': recovery, 'platform': platform})

    def put(self, revision, data, token=None):
        return self.call('PUT', token=token, json={'revision': revision, 'data': data})

    def revoke(self, token=None):
        with sqlite3.connect(self.root / 'control.sqlite3') as db:
            device = db.execute('SELECT id FROM devices WHERE hash=?',
                                (hashlib.sha256((token or self.token).encode()).hexdigest(),)).fetchone()[0]
        client = self.app.test_client()
        with client.session_transaction(**self.base) as session:
            session.update(owner=True, csrf='test-csrf')
        return client.post('/admin/devices/' + device + '/revoke', data={'csrf': 'test-csrf'}, **self.base)

    def test_ownership_restart_and_no_external_identifiers(self):
        self.assertEqual(self.call('GET').status_code, 409)
        self.assertEqual(self.bind().json, {'revision': 0, 'data': None})
        second = self.enroll().json['token']
        self.assertEqual(self.bind('2' * 64, second, 'android').status_code, 200)
        first_data = {'favorites': ['synthetic-first'], 'nested': {'skipCount': 3}}
        second_data = {'favorites': ['synthetic-second']}
        self.assertEqual(self.put(0, first_data).json, {'revision': 1, 'data': first_data})
        self.assertEqual(self.put(0, second_data, second).status_code, 200)
        self.assertEqual(self.call('GET').json['data'], first_data)
        self.assertEqual(self.call('GET', token=second).json['data'], second_data)
        self.assertEqual(self.call('GET', path='/v1/library?device=other').status_code, 400)
        self.assertEqual(self.call('PUT', json={'revision': 1, 'data': {}, 'profile': 'other'}).status_code, 400)
        self.assertEqual(self.bind('3' * 64).status_code, 403)
        self.assertEqual(self.bind('2' * 64).status_code, 403)
        self.assertEqual(self.call('GET', token=self.ticket).status_code, 401)
        self.assertEqual(self.app.test_client().get('/v1/library', **self.base).status_code, 401)
        self.app = make_app(self.root, FixtureQQ())
        self.assertEqual(self.call('GET').json['data'], first_data)
        self.assertEqual(self.bind().json, {'revision': 1, 'data': first_data})
        with sqlite3.connect(self.root / 'control.sqlite3') as db:
            stored = db.execute('SELECT recovery_hash FROM library_profiles').fetchall()
            self.assertNotIn('1' * 64, [row[0] for row in stored])
            self.assertEqual(db.execute('SELECT count(*) FROM library_profiles').fetchone()[0], 2)

    def test_cas_duplicate_retries_and_simultaneous_writers(self):
        self.bind()
        first = {'a': 1, 'b': [2, 3]}
        self.assertEqual(self.put(0, first).json['revision'], 1)
        self.assertEqual(self.put(0, {'b': [2, 3], 'a': 1}).json['revision'], 1)
        self.assertEqual(self.put(1, first).json['revision'], 1)
        conflict = self.put(0, {'a': 9})
        self.assertEqual(conflict.status_code, 409)
        self.assertEqual(conflict.json, {'revision': 1, 'data': first})
        with concurrent.futures.ThreadPoolExecutor(2) as pool:
            responses = list(pool.map(lambda number: self.put(1, {'number': number}), [4, 5]))
        self.assertEqual(sorted(response.status_code for response in responses), [200, 409])
        self.assertEqual(self.call('GET').json['revision'], 2)
        current = self.call('GET').json['data']
        self.assertEqual(self.put(0, current).status_code, 409)
        self.assertEqual(self.put(1, current).json['revision'], 2)
        self.assertEqual(self.put(3, current).status_code, 409)

    def test_reinstall_bind_retires_previous_session_and_keeps_data(self):
        self.bind()
        data = {'history': ['synthetic-track'], 'taste': {'style': 'jazz'}}
        self.put(0, data)
        replacement = self.enroll().json['token']
        self.assertEqual(self.bind(token=replacement).json, {'revision': 1, 'data': data})
        self.assertEqual(self.call('GET').status_code, 401)
        self.assertEqual(self.call('GET', token=replacement).json['data'], data)
        self.assertEqual(self.enroll(self.installation, '1' * 64).status_code, 403)
        self.assertEqual(self.bind(token=replacement).json['revision'], 1)

    def test_full_capacity_recovery_retry_pause_and_revocation(self):
        manifest = [{'ticket_hash': hashlib.sha256(self.ticket.encode()).hexdigest(), 'device_limit': 1}]
        (self.root / 'private-builds.json').write_text(json.dumps(manifest))
        self.app = make_app(self.root, FixtureQQ())
        self.bind()
        saved = {'favorites': ['capacity-fixture']}
        self.put(0, saved)
        self.assertEqual(self.enroll().status_code, 403)
        with sqlite3.connect(self.root / 'control.sqlite3') as db:
            db.execute("UPDATE settings SET val=0 WHERE key='auto_enrollment'")
        replacement_id = str(uuid.uuid4())
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            replies = list(pool.map(lambda _: self.enroll(replacement_id, '1' * 64), range(3)))
        self.assertEqual(sorted(response.status_code for response in replies), [200, 200, 201])
        replacement = replies[0].json['token']
        self.assertTrue(all(response.json['token'] == replacement for response in replies))
        self.assertEqual(self.call('GET', token=replacement).json['data'], saved)
        self.assertEqual(self.call('GET').status_code, 401)
        with sqlite3.connect(self.root / 'control.sqlite3') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM devices').fetchone()[0], 1)
        self.app = make_app(self.root, FixtureQQ())
        self.assertEqual(self.enroll(replacement_id, '1' * 64).json['token'], replacement)
        self.assertEqual(self.revoke(replacement).status_code, 302)
        self.assertEqual(self.call('GET', token=replacement).status_code, 401)
        self.assertEqual(self.enroll(str(uuid.uuid4()), '1' * 64).status_code, 403)
        self.assertEqual(self.enroll(replacement_id, '1' * 64).status_code, 403)
        with sqlite3.connect(self.root / 'control.sqlite3') as db:
            self.assertEqual(db.execute('SELECT data FROM library_profiles').fetchone()[0],
                             json.dumps(saved, separators=(',', ':'), sort_keys=True))

    def test_cross_platform_and_revoked_bind_cannot_take_over(self):
        self.bind()
        other = self.enroll().json['token']
        self.assertEqual(self.bind(token=other, platform='android').status_code, 403)
        self.assertEqual(self.enroll(recovery='1' * 64, platform='android').status_code, 403)
        self.assertEqual(self.bind('2' * 64, other).status_code, 200)
        self.assertEqual(self.enroll(self.installation, '2' * 64).status_code, 403)
        self.assertEqual(self.enroll(self.installation, '3' * 64).status_code, 403)
        self.revoke()
        third = self.enroll().json['token']
        self.assertEqual(self.bind(token=third).status_code, 403)
        self.assertEqual(self.bind('3' * 64, third).status_code, 200)

    def test_shape_limits_and_non_json_data(self):
        self.bind()
        large = {'notes': 'a' * 24000}
        self.assertEqual(self.put(0, large).status_code, 200)
        self.assertEqual(self.call('GET').json['data'], large)
        self.assertEqual(self.put(1, {'notes': 'a' * (4 * 1024 * 1024)}).status_code, 413)
        self.assertEqual(self.call('POST', '/v1/library/bind', json={
            'recovery': '1' * 64, 'platform': 'ios', 'padding': 'a' * 17000}).status_code, 413)
        for bad in [[], None, {'revision': True, 'data': {}}, {'revision': -1, 'data': {}},
                    {'revision': 2 ** 53, 'data': {}}, {'revision': 1, 'data': []}]:
            self.assertEqual(self.call('PUT', json=bad).status_code, 400)
        for value in ('NaN', 'Infinity', '"\\ud800"'):
            body = '{"revision":1,"data":{"bad":' + value + '}}'
            self.assertEqual(self.call('PUT', data=body, content_type='application/json').status_code, 400)
        body = '{"revision":1,"data":{"bad":' + '[' * 70 + '0' + ']' * 70 + '}}'
        self.assertEqual(self.call('PUT', data=body, content_type='application/json').status_code, 400)
        self.assertEqual(self.call('GET').json, {'revision': 1, 'data': large})


if __name__ == '__main__':
    unittest.main()
