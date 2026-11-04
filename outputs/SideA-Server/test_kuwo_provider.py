import json
import unittest
from unittest.mock import patch

import kuwo_provider as kuwo


class Response:
    def __init__(self, data=b'', status=200, headers=None):
        self.data, self.status_code, self.headers = data, status, headers or {}
    def __enter__(self): return self
    def __exit__(self, *args): pass
    def iter_content(self, size):
        for offset in range(0, len(self.data), size): yield self.data[offset:offset + size]


class KuwoTests(unittest.TestCase):
    def setUp(self):
        kuwo._metadata.clear()
        self.dns = patch.object(kuwo.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('8.8.8.8', 443))])
        self.dns.start()
    def tearDown(self): self.dns.stop()

    def test_public_search_normalizes_text_and_excludes_short_fragments(self):
        payload = {'abslist': [
            {'MUSICRID': 'MUSIC_11', 'NAME': '测试&nbsp;歌', 'ARTIST': '歌手\\u0026乐队', 'ALBUM': '专辑', 'DURATION': '200', 'PAY': '0'},
            {'MUSICRID': 'MUSIC_12', 'NAME': '测试歌', 'DURATION': '13'},
            {'MUSICRID': 'bad', 'NAME': '错误编号', 'DURATION': '200'}]}
        with patch.object(kuwo, '_fetch', return_value=str(payload)) as fetch:
            rows = kuwo.search('测试', 2, 20)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['artist'], ['歌手&乐队'])
        self.assertEqual(rows[0]['name'], '测试\xa0歌')
        self.assertEqual(rows[0]['source'], 'kuwo')
        self.assertEqual(fetch.call_args.args[1]['pn'], 1)
        self.assertNotIn('verifiedCatalogOriginal', rows[0])

    def test_data_parser_never_executes_and_bounds_size(self):
        self.assertEqual(kuwo._decode('{"abslist":[]}'), {'abslist': []})
        for invalid in ["__import__('os').system('false')", '[]', '{' * 5000, ' ' * (1536 * 1024 + 1)]:
            with self.assertRaises(kuwo.KuwoError): kuwo._decode(invalid)
        with patch.object(kuwo.requests, 'get', return_value=Response(b'x' * 8200)):
            with self.assertRaises(kuwo.KuwoError): kuwo._fetch(kuwo.RESOLVE, maximum=8192)

    def test_strict_ids_https_allowlist_private_network_and_no_redirects(self):
        for identity in ('1/../../x', '0', '-1', 'MUSIC_1', '1?url=private'):
            with self.assertRaises(kuwo.KuwoError): kuwo.url(identity, 128)
        for address in ('http://kw-bj.kuwo.cn/a.mp3', 'https://kw-bj.kuwo.cn.evil.test/a',
                        'https://u:p@kw-bj.kuwo.cn/a', 'https://127.0.0.1/a', 'https://kw-bj.kuwo.cn:444/a'):
            with self.assertRaises(kuwo.KuwoError): kuwo._safe_url(address, 'audio')
        with patch.object(kuwo.socket, 'getaddrinfo', return_value=[(2, 1, 6, '', ('10.0.0.1', 443))]):
            with self.assertRaises(kuwo.KuwoError): kuwo._safe_url('https://kw-bj.kuwo.cn/a', 'audio')
        with patch.object(kuwo.requests, 'get', return_value=Response(status=302)) as get:
            with self.assertRaises(kuwo.KuwoError): kuwo._probe('https://kw-bj.kuwo.cn/a.mp3', 200)
            self.assertFalse(get.call_args.kwargs['allow_redirects'])

    def test_actual_mp3_rate_and_preview_rejection(self):
        frame = bytes.fromhex('fffb9000') + b'\0' * 413
        body = frame * 4
        kuwo._remember('11', {'duration': 200, 'paid': False})
        with patch.object(kuwo, '_fetch', return_value='https://kw-bj.kuwo.cn/audio.mp3'), \
             patch.object(kuwo.requests, 'get', return_value=Response(body, headers={'Content-Length': '3200000'})):
            result = kuwo.url('11', 320)
        self.assertEqual(result['br'], 128)
        self.assertTrue(result['url'].startswith('https://'))
        with patch.object(kuwo, '_fetch', return_value='https://kw-bj.kuwo.cn/audio.mp3'), \
             patch.object(kuwo.requests, 'get', return_value=Response(body, headers={'Content-Length': '214122'})):
            denied = kuwo.url('11', 128)
        self.assertEqual(denied['url'], '')
        self.assertIn('片段', denied['message'])
        self.assertEqual(denied['br'], 0)

    def test_permissions_and_unverified_lossless_are_never_bypassed(self):
        for quality in (740, 999):
            with patch.object(kuwo, '_fetch') as fetch:
                self.assertEqual(kuwo.url('11', quality)['url'], '')
                fetch.assert_not_called()
        kuwo._remember('11', {'paid': True})
        with patch.object(kuwo, '_fetch') as fetch:
            self.assertIn('授权', kuwo.url('11', 128)['message'])
            fetch.assert_not_called()
        kuwo._metadata.clear()
        kuwo._remember('11', {'duration': 200, 'paid': False})
        with patch.object(kuwo, '_fetch', return_value='https://kw-er.kuwo.cn/a.mp3'), \
             patch.object(kuwo.requests, 'get', return_value=Response(status=403)):
            self.assertIn('未授权', kuwo.url('11', 128)['message'])

    def test_expired_metadata_requires_official_duration_and_preserves_paid_flag(self):
        kuwo._metadata['11'] = (0, {'duration': 200, 'paid': False})
        with patch.object(kuwo, '_info', return_value={'songinfo': {'duration': '200', 'PAY': '0'}}) as info, \
             patch.object(kuwo, '_fetch', return_value='https://kw-bj.kuwo.cn/a.mp3'), \
             patch.object(kuwo, '_probe', return_value=(128, 3200000)) as probe:
            self.assertTrue(kuwo.url('11', 128)['url'])
            info.assert_called_once_with('11')
            self.assertEqual(probe.call_args.args[1], 200)
        for song, expected in [({}, '无法验证'), ({'duration': '0'}, '无法验证'),
                               ({'duration': '200', 'pay': '1'}, '授权')]:
            kuwo._metadata.clear()
            with patch.object(kuwo, '_info', return_value={'songinfo': song}), patch.object(kuwo, '_fetch') as fetch:
                result = kuwo.url('11', 128)
                self.assertEqual(result['url'], '')
                self.assertIn(expected, result['message'])
                fetch.assert_not_called()

    def test_unavailable_artwork_and_lyrics_are_safe_empty_values(self):
        with patch.object(kuwo, '_info', return_value={}):
            self.assertEqual(kuwo.pic('11', 500), {'url': ''})
            self.assertEqual(kuwo.lyric('11'), {'lyric': '', 'tlyric': ''})
        with patch.object(kuwo, '_info', return_value={'songinfo': {'pic': 'http://img1.kwcdn.kuwo.cn/x.png'},
                'lrclist': [{'time': '61.5', 'lineLyric': '合成测试行'}, {'time': '-1', 'lineLyric': 'bad'}]}):
            self.assertEqual(kuwo.pic('11', 500)['url'], '')
            self.assertEqual(kuwo.lyric('11')['lyric'], '[01:01.50]合成测试行')


if __name__ == '__main__': unittest.main()
