"""Synthetic authenticated end-to-end bridge contract; never uses a real model/key."""
import hashlib
import json
import os
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from server import make_app
from test_server import FixtureQQ


class Reply:
    status_code = 200
    def __init__(self, task): self.payload = json.dumps({'ok': True, 'task': task}).encode()
    def __enter__(self): return self
    def __exit__(self, *_): pass
    def iter_content(self, _): yield self.payload


class AIBridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.ticket = 'Q' * 43
        (self.root/'private-builds.json').write_text(json.dumps([{'ticket_hash': hashlib.sha256(self.ticket.encode()).hexdigest(), 'device_limit': 8}]))
        with patch.dict(os.environ, {'SIDEA_AI_HUB_URL': 'http://127.0.0.1:18080', 'SIDEA_AI_HUB_KEY': 'synthetic-app-key'}):
            self.app = make_app(self.root, FixtureQQ())
        self.token = self.enroll()
        self.call('POST', '/v1/library/bind', json={'recovery': 'a'*64, 'platform': 'ios'})
        self.payload = {'profile': {'favorites': [{'title': 'Fixture', 'artist': 'Artist'}]},
                        'candidates': [{'id': 'b'*64, 'title': 'Candidate', 'artist': 'Artist'}]}

    def tearDown(self): self.tmp.cleanup()
    def enroll(self, recovery=None):
        body = {'installation': str(uuid.uuid4()), 'name': 'fixture'}
        if recovery: body.update(recovery=recovery, platform='ios')
        return self.app.test_client().post('/v1/enroll', json=body, headers={'Authorization': 'SideA-Setup '+self.ticket}).json['token']
    def call(self, method, path='/v1/ai/recommend', token=None, **kwargs):
        return self.app.test_client().open(path, method=method, headers={'Authorization': 'Bearer '+(token or self.token)}, **kwargs)

    def test_identity_is_server_owned_stable_after_reinstall_and_isolated(self):
        calls=[]
        def hub(method, url, **kw):
            calls.append(kw)
            return Reply({'id': 'task-fixture', 'status': 'queued'})
        with patch('ai_bridge.requests.request', hub):
            self.assertEqual(self.call('POST', json=self.payload).status_code, 200)
            first=calls[-1]['json']['subject']
            self.assertEqual(calls[-1]['headers']['Authorization'], 'Bearer synthetic-app-key')
            other=self.enroll(); self.call('POST','/v1/library/bind',token=other,json={'recovery':'c'*64,'platform':'ios'})
            self.call('GET','/v1/ai/tasks/task-fixture',token=other)
            self.assertNotEqual(first,calls[-1]['params']['subject'])
            new=self.enroll('a'*64)
            self.assertEqual(self.call('POST',token=new,json=self.payload).status_code,200)
            self.assertEqual(first,calls[-1]['json']['subject'])
            self.assertEqual(self.call('POST',json=self.payload).status_code,401)

    def test_input_identity_and_urls_cannot_escape_bridge(self):
        with patch('ai_bridge.requests.request') as hub:
            for bad in [dict(self.payload,subject='other'),dict(self.payload,candidates=[{'id':'https://internal/secret','title':'x','artist':'x'}]),dict(self.payload,profile={'x':'x'*6000})]:
                self.assertEqual(self.call('POST',json=bad).status_code,400)
            self.assertEqual(self.call('GET','/v1/ai/tasks/abc?subject=other').status_code,400)
            self.assertEqual(self.call('POST',token='unknown',json=self.payload).status_code,401)
            hub.assert_not_called()

    def test_retry_payload_and_filtered_failure(self):
        with patch('ai_bridge.requests.request', return_value=Reply({'id':'test','status':'queued','provider_key':'never-relay'})) as hub:
            first=self.call('POST',json=self.payload)
            body=hub.call_args.kwargs['json']
            second=self.call('POST',json=self.payload)
            self.assertEqual(body,hub.call_args.kwargs['json'])
            self.assertNotIn('idempotency_key',body)
            self.assertNotIn('provider_key',first.json['task'])
            self.assertEqual(first.json,second.json)
        bad=Reply({});bad.status_code=500
        with patch('ai_bridge.requests.request',return_value=bad):
            self.assertEqual(self.call('POST',json=self.payload).json,{'ok':False,'error':{'code':'ai_unavailable'}})

    def test_no_configuration_is_not_fake_ai_success(self):
        with patch.dict(os.environ,{'SIDEA_AI_HUB_URL':'','SIDEA_AI_HUB_KEY':''}):
            self.app=make_app(self.root,FixtureQQ())
        self.assertEqual(self.call('POST',json=self.payload).status_code,503)
        self.assertEqual(self.call('POST',json=self.payload).json['error']['code'],'model_unconfigured')

    def test_configuration_is_read_only_scoped_and_filtered(self):
        reply=Reply({})
        reply.payload=json.dumps({'ok':True,'config':{'revision':'f'*64,'enabled':True,'key':'do-not-forward'}}).encode()
        with patch('ai_bridge.requests.request',return_value=reply) as hub:
            response=self.call('GET','/v1/ai/config')
            self.assertEqual(response.json,{'ok':True,'config':{'revision':'f'*64,'enabled':True}})
            self.assertEqual(hub.call_args.args,('GET','http://127.0.0.1:18080/v1/config'))
            self.assertEqual(self.call('GET','/v1/ai/config',token='unknown').status_code,401)

    def test_long_chinese_candidates_fit_utf8_model_budget(self):
        payload={'profile':{'favorites':['中'*80]*30},'candidates':[
            {'id':hashlib.sha256(str(i).encode()).hexdigest(),'title':'歌'*80,'artist':'人'*80,'album':'碟'*80} for i in range(60)]}
        with patch('ai_bridge.requests.request',return_value=Reply({'id':'fixture','status':'queued'})) as hub:
            self.assertEqual(self.call('POST',json=payload).status_code,200)
            forwarded=hub.call_args.kwargs['json']['input']
            self.assertLessEqual(len(json.dumps(forwarded,ensure_ascii=False).encode()),28000)
            self.assertLess(len(forwarded['candidates']),60)
            self.assertEqual(forwarded['limit'],min(24,len(forwarded['candidates'])))

    def test_pending_cancellation_keeps_device_subject(self):
        with patch('ai_bridge.requests.request',return_value=Reply({'id':'task-fixture','status':'cancelled'})) as hub:
            response=self.call('POST','/v1/ai/tasks/task-fixture/cancel',json={})
            self.assertEqual(response.json['task']['status'],'cancelled')
            self.assertTrue(hub.call_args.kwargs['json']['subject'].startswith('library-'))
            self.assertEqual(self.call('POST','/v1/ai/tasks/task-fixture/cancel',json={'subject':'other'}).status_code,400)

if __name__ == '__main__': unittest.main()
