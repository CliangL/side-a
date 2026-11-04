import concurrent.futures
import hashlib
import json
import sqlite3
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

import catalog
from server import make_app


class FixtureQQ:
    def __init__(self): self.published='专辑原版'; self.bound=False
    def status(self): return {'connected':self.bound, 'message':'测试账号'}
    def start_login(self,method):
        self.method=method
        return {'status':'pending'}
    def search(self,query,page,count):
        return [{'id':'album-42','name':query,'album':self.published,'artist':['测试歌手'],
                 'source':'tencent','pic_id':'cover/中文+','lyric_id':'verse'}]
    def url(self,identity,br):
        if not self.bound:return {'url':'','br':0,'message':'当前账号没有权限'}
        return {'url':'https://cdn.example.test/album.flac?temporary=1','br':1411,'size':1234}
    def pic(self,identity,size):return {'url':'https://cdn.example.test/pic.jpg'}
    def lyric(self,identity):return {'lyric':'[00:00.00]测试','tlyric':''}


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.qq=FixtureQQ()
        self.app=make_app(self.root,self.qq)
        self.c=self.app.test_client()
        with self.c.session_transaction(base_url='https://sidea.test') as s:s.update(owner=True,csrf='test-csrf')
        self.base={'base_url':'https://sidea.test'}
        for source in ('wy','jx','kw'):
            self.c.post('/admin/providers/'+source+'/update',data={'name':source,'priority':'30','csrf':'test-csrf'},**self.base)
    def tearDown(self): self.temp.cleanup()

    def invite(self):
        self.assertEqual(self.c.post('/admin/invite',data={'csrf':'test-csrf'},**self.base).status_code,302)
        with self.c.session_transaction(**self.base) as s:return s['new_invite']

    def pair(self,code,name='手机'):
        return self.app.test_client().post('/v1/pair',json={'code':code,'name':name},**self.base)

    def call(self,token,kind,**params):
        return self.app.test_client().get('/v1/music',headers={'Authorization':'Bearer '+token},
            query_string={'source':'central','types':kind,**params},**self.base)

    def test_two_devices_share_settings_and_revocation_is_individual(self):
        a=self.pair(self.invite(),'iPhone').json['token']; b=self.pair(self.invite(),'Android').json['token']
        self.assertNotEqual(a,b)
        rows=self.call(a,'search',name='测试').json; entry=rows[0]
        self.assertEqual(entry['id'],self.call(b,'search',name='测试').json[0]['id'])
        self.assertEqual(entry['source'],'central')
        self.assertFalse(self.call(a,'url',id=entry['id']).json['url'])
        self.qq.bound=True
        self.assertIn('cdn.example.test',self.call(b,'url',id=entry['id']).json['url'])
        self.assertNotIn(b,self.call(b,'url',id=entry['id']).get_data(as_text=True))
        self.assertEqual(self.call(b,'lyric',id=entry['lyric_id']).json['lyric'],'[00:00.00]测试')
        self.qq.published='新目录'
        self.c.post('/admin/providers/qq/update',data={'name':'我的 QQ','enabled':'on','priority':'1','csrf':'test-csrf'},**self.base)
        self.assertEqual(self.call(a,'search',name='测试').json[0]['album'],'新目录')
        self.assertEqual(self.call(b,'search',name='测试').json[0]['album'],'新目录')
        import sqlite3
        with sqlite3.connect(self.root/'control.sqlite3') as db: idx=db.execute("SELECT id FROM devices WHERE name='iPhone'").fetchone()[0]
        self.c.post('/admin/devices/'+idx+'/revoke',data={'csrf':'test-csrf'},**self.base)
        self.assertEqual(self.call(a,'search',name='测试').status_code,401)
        self.assertEqual(self.call(b,'search',name='测试').status_code,200)
        other=make_app(self.root,self.qq).test_client()
        self.assertEqual(other.get('/v1/music?source=central&types=search&name=测试',headers={'Authorization':'Bearer '+b},**self.base).status_code,200)
    def test_single_use_atomic_and_csrf(self):
        self.assertEqual(self.c.post('/admin/invite',data={'csrf':'wrong'},**self.base).status_code,403)
        otp=self.invite()
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            status=list(pool.map(lambda _:self.pair(otp).status_code,range(3)))
        self.assertEqual(sorted(status),[201,403,403])
        self.assertEqual(self.app.test_client().get('/v1/music').status_code,401)
        self.assertEqual(self.app.test_client().get('/admin/qq/status/pending').status_code,401)

    def test_qq_scope_only_queries_qq_and_preserves_aggregate_track_identity(self):
        token=self.pair(self.invite()).json['token']
        self.c.post('/admin/providers/wy/update',data={'name':'网易云音乐','priority':'20','enabled':'on','csrf':'test-csrf'},**self.base)
        row={'id':'album-42','name':'同名金曲','artist':['其他歌手'],'source':'netease'}
        with patch.object(catalog,'call_gd',return_value=[row]) as gd:
            filtered=self.call(token,'search',name='同名金曲',provider='qq')
            self.assertEqual(filtered.status_code,200)
            self.assertEqual([r['provider_id'] for r in filtered.json],['qq'])
            gd.assert_not_called()
            aggregate=self.call(token,'search',name='同名金曲')
            self.assertEqual([r['provider_id'] for r in aggregate.json],['qq','wy'])
            self.assertEqual(aggregate.json[0],filtered.json[0])
            self.assertEqual(filtered.json[0]['source'],'central')
            self.assertEqual(self.call(token,'lyric',id=filtered.json[0]['lyric_id']).status_code,200)
            self.assertEqual(gd.call_count,1)
            self.c.post('/admin/providers/qq/update',data={'name':'QQ 音乐','priority':'1','csrf':'test-csrf'},**self.base)
            self.assertEqual(self.call(token,'search',name='同名金曲',provider='qq').status_code,404)
            self.assertEqual(self.call(token,'search',name='同名金曲',provider='unknown').status_code,404)
            for invalid in ('','qq/wy',['qq','wy']):
                self.assertEqual(self.call(token,'search',name='同名金曲',provider=invalid).status_code,400)
            self.assertEqual(gd.call_count,1)
    def test_qr_method_selection_requires_owner_and_csrf(self):
        path='/admin/qq/login'
        self.assertEqual(self.app.test_client().post(path,**self.base).status_code,401)
        self.assertEqual(self.c.post(path,data={'method':'qq'},**self.base).status_code,403)
        for value, expected in (({},'qq'),({'method':'mobile'},'mobile')):
            response=self.c.post(path,data={'csrf':'test-csrf',**value},**self.base)
            self.assertEqual(response.json['status'],'pending')
            self.assertEqual(self.qq.method,expected)
        self.assertEqual(self.c.post(path,data={'method':'other','csrf':'test-csrf'},**self.base).status_code,400)

    def test_private_enrollment_retry_cap_revoke_and_pause(self):
        ticket='A'*43
        manifest=[dict(ticket_hash=hashlib.sha256(ticket.encode()).hexdigest(),device_limit=1)]
        (self.root/'private-builds.json').write_text(json.dumps(manifest))
        server=make_app(self.root,self.qq)
        def enroll(install,auth=ticket):
            return server.test_client().post('/v1/enroll',headers={'Authorization':'SideA-Setup '+auth},
                json={'name':'这台手机','installation':install},**self.base)
        one=str(uuid.uuid4()); two=str(uuid.uuid4())
        self.assertEqual(enroll(one,'B'*43).status_code,403)
        self.assertEqual(enroll('not-a-uuid').status_code,400)
        self.assertEqual(server.test_client().post('/v1/enroll',json={}).status_code,403)
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            responses=list(pool.map(enroll,[one]*3))
        self.assertEqual(sorted(r.status_code for r in responses),[200,200,201])
        token=responses[0].json['token']
        self.assertTrue(all(r.json['token']==token for r in responses))
        self.assertEqual(self.call(token,'search',name='好歌').status_code,200)
        self.assertEqual(self.call(ticket,'search',name='好歌').status_code,401)
        self.assertEqual(enroll(two).status_code,403)
        with sqlite3.connect(self.root/'control.sqlite3') as db:
            device=db.execute('SELECT id FROM devices').fetchone()[0]
        self.c.post('/admin/devices/'+device+'/revoke',data={'csrf':'test-csrf'},**self.base)
        self.assertEqual(self.call(token,'search',name='好歌').status_code,401)
        self.assertEqual(enroll(one).status_code,403)
        self.assertEqual(self.c.post('/admin/enrollment',data={'enabled':'0'},**self.base).status_code,403)
        self.c.post('/admin/enrollment',data={'enabled':'0','csrf':'test-csrf'},**self.base)
        self.assertEqual(enroll(two).status_code,403)
        self.c.post('/admin/enrollment',data={'enabled':'1','csrf':'test-csrf'},**self.base)
        self.assertEqual(enroll(two).status_code,201)
        server=make_app(self.root,self.qq)
        self.assertEqual(enroll(two).status_code,200)
        self.assertEqual(enroll(one).status_code,403)
    def test_mount_and_sanitized_urls(self):
        with patch.dict('os.environ',{'SIDEA_PUBLIC_BASE':'https://my.example/sidea'}):
            app=make_app(self.root,self.qq);c=app.test_client()
            reply=c.get('/login',headers={'X-Forwarded-Prefix':'//unexpected.example'},**self.base)
            self.assertEqual(reply.status_code,200)
            self.assertIn('Path=/sidea',reply.headers.get('Set-Cookie',''))
            self.assertNotIn('unexpected.example',reply.get_data(as_text=True))
        for addr in ('http://music.example/api.php','https://127.0.0.1/api.php','https://u:p@example.org/api'):
            with self.assertRaises(catalog.CatalogError): catalog.trusted_endpoint(addr)
        for value in ('','../bad','../bad.key','q.bad!'):
            with self.assertRaises(catalog.CatalogError): catalog.unpack(value)


if __name__=='__main__':unittest.main()
