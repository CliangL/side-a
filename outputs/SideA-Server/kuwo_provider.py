"""Read public Kuwo metadata and validate its public MP3 response before playback.

No login emulation, CDN hostname rewriting, paid URL variants or lossless claims.
"""
import ast
import html
import ipaddress
import json
import re
import socket
import threading
import time
from urllib.parse import urlsplit

import requests


class KuwoError(Exception):
    pass


SEARCH = 'https://search.kuwo.cn/r.s'
RESOLVE = 'https://antiserver.kuwo.cn/anti.s'
INFO = 'https://m.kuwo.cn/newh5/singles/songinfoandlrc'
_metadata = {}
_lock = threading.Lock()


def _id(value):
    value = str(value)
    if not re.fullmatch('[1-9][0-9]{0,17}', value):
        raise KuwoError('酷我曲目编号无效。')
    return value


def _safe_url(value, kind):
    if not isinstance(value, str) or len(value) > 4096 or any(c.isspace() for c in value):
        raise KuwoError('酷我返回的地址无效。')
    try:
        u = urlsplit(value)
        allowed = (u.hostname in ('search.kuwo.cn', 'antiserver.kuwo.cn', 'm.kuwo.cn') if kind == 'api' else
                   bool(re.fullmatch(r'kw-[a-z0-9-]+\.kuwo\.cn', u.hostname or '')) if kind == 'audio' else
                   bool(re.fullmatch(r'img[0-9]+\.(?:kwcdn\.)?kuwo\.cn', u.hostname or '')))
        if (u.scheme != 'https' or not allowed or u.username is not None or u.password is not None
                or u.fragment or u.port not in (None, 443)):
            raise ValueError()
        addresses = socket.getaddrinfo(u.hostname, 443, type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(item[4][0]).is_global for item in addresses):
            raise ValueError()
    except (ValueError, OSError):
        raise KuwoError('酷我返回的地址不可用。')
    return value


def _fetch(address, params=None, maximum=1536 * 1024):
    _safe_url(address, 'api')
    try:
        with requests.get(address, params=params, timeout=(3, 7), allow_redirects=False, stream=True,
                          headers={'User-Agent': 'SideA/0.4'}) as response:
            if response.status_code != 200:
                raise KuwoError('酷我接口暂时不可用。')
            data = bytearray()
            for chunk in response.iter_content(16384):
                data.extend(chunk)
                if len(data) > maximum:
                    raise KuwoError('酷我返回的数据过大。')
        return data.decode('utf-8')
    except (requests.RequestException, UnicodeError):
        raise KuwoError('酷我暂时无法连接。')


def _decode(raw):
    if len(raw.encode('utf-8')) > 1536 * 1024:
        raise KuwoError('酷我返回的数据过大。')
    try:
        try:
            result = json.loads(raw)
        except ValueError:
            # This public endpoint sometimes emits a Python-literal dictionary.
            # literal_eval accepts data only; never execute its text.
            result = ast.literal_eval(raw)
        if not isinstance(result, dict):
            raise ValueError()
        return result
    except (ValueError, SyntaxError, RecursionError, TypeError, MemoryError):
        raise KuwoError('酷我返回的资料格式无效。')


def _text(value):
    return html.unescape(re.sub(r'\\+u0026', '&', str(value or ''))).strip()[:2048]


def _remember(identity, value):
    with _lock:
        if len(_metadata) >= 512:
            _metadata.clear()
        _metadata[identity] = (time.monotonic() + 900, value)


def _known(identity):
    with _lock:
        cached = _metadata.get(identity)
        return dict(cached[1]) if cached and cached[0] > time.monotonic() else {}


def search(query, page, count):
    if not isinstance(query, str) or not query.strip() or len(query) > 150 or not 1 <= page <= 100 or not 1 <= count <= 50:
        raise KuwoError('酷我搜索参数无效。')
    result = _decode(_fetch(SEARCH, {'all': query, 'ft': 'music', 'client': 'kt', 'pn': page - 1,
                                    'rn': count, 'rformat': 'json', 'encoding': 'utf8'}))
    rows = result.get('abslist')
    if not isinstance(rows, list):
        raise KuwoError('酷我未返回歌曲列表。')
    output = []
    for row in rows[:count]:
        if not isinstance(row, dict):
            continue
        match = re.fullmatch(r'MUSIC_([1-9][0-9]{0,17})', str(row.get('MUSICRID', '')))
        title = _text(row.get('NAME'))
        try:
            duration = int(row.get('DURATION', 0))
        except (TypeError, ValueError):
            continue
        # Search can include social clips under the same song/artist. Do not offer obvious fragments.
        if not match or not title or duration < 60:
            continue
        identity = match[1]
        _remember(identity, {'duration': duration, 'paid': str(row.get('PAY', '0')) != '0'})
        output.append({'id': identity, 'name': title, 'artist': [_text(row.get('ARTIST'))],
                       'album': _text(row.get('ALBUM')), 'source': 'kuwo',
                       'pic_id': identity, 'lyric_id': identity})
    return output


def _info(identity):
    result = _decode(_fetch(INFO, {'musicId': identity}))
    data = result.get('data')
    return data if isinstance(data, dict) else {}


def _playback_metadata(identity):
    metadata = _known(identity)
    if metadata.get('paid') or metadata.get('duration', 0) > 0:
        return metadata
    song = _info(identity).get('songinfo')
    if not isinstance(song, dict):
        raise KuwoError('酷我暂未提供完整录音资料，无法验证全曲。')
    try:
        duration = int(song.get('duration', 0))
    except (TypeError, ValueError):
        duration = 0
    if not 0 < duration < 86400:
        raise KuwoError('酷我暂未提供录音时长，无法验证全曲。')
    paid = song.get('PAY', song.get('pay', 0))
    metadata = {'duration': duration, 'paid': paid not in (None, False, 0, '0', '')}
    _remember(identity, metadata)
    return metadata


def _mp3_rate(data):
    # Validate two MPEG Layer III frame headers, rather than trusting a URL suffix or requested quality.
    for offset in range(max(0, len(data) - 4)):
        header = int.from_bytes(data[offset:offset + 4], 'big')
        version, layer, rate_index, sample_index = (header >> 19) & 3, (header >> 17) & 3, (header >> 12) & 15, (header >> 10) & 3
        if header >> 21 != 0x7ff or version == 1 or layer != 1 or rate_index in (0, 15) or sample_index == 3:
            continue
        rates = [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320] if version == 3 else [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        sample = [44100, 48000, 32000][sample_index] // (1 if version == 3 else 2 if version == 2 else 4)
        rate = rates[rate_index]
        next_offset = offset + (144000 if version == 3 else 72000) * rate // sample + ((header >> 9) & 1)
        if next_offset + 4 <= len(data):
            next_header = int.from_bytes(data[next_offset:next_offset + 4], 'big')
            if next_header & 0xfffe0c00 == header & 0xfffe0c00:
                return rate
    raise KuwoError('酷我未返回可验证的音频。')


def _probe(address, expected):
    _safe_url(address, 'audio')
    try:
        with requests.get(address, headers={'Range': 'bytes=0-32767', 'User-Agent': 'Mozilla/5.0',
                                            'Referer': 'https://www.kuwo.cn/'},
                          stream=True, allow_redirects=False, timeout=(3, 7)) as response:
            if response.status_code not in (200, 206):
                raise KuwoError('酷我未授权此录音的完整播放。')
            header = response.headers.get('Content-Range', '')
            total = int(header.rsplit('/', 1)[-1]) if response.status_code == 206 and '/' in header else int(response.headers.get('Content-Length', 0))
            data = bytearray()
            for chunk in response.iter_content(4096):
                data.extend(chunk)
                if len(data) >= 32768:
                    break
        rate = _mp3_rate(data)
        duration = total * 8 / (rate * 1000)
        if total <= 0 or duration < 60 or (expected and duration < expected * .8):
            raise KuwoError('酷我当前仅返回片段，无法完整播放。')
        return rate, total
    except (requests.RequestException, ValueError):
        raise KuwoError('酷我音频暂时无法连接。')


def url(identity, br):
    identity = _id(identity)
    empty = {'url': '', 'br': 0, 'size': 0}
    if br in (740, 999):
        return {**empty, 'message': '酷我当前公开接口暂无可验证的无损音源。'}
    try:
        info = _playback_metadata(identity)
        if info.get('paid'):
            return {**empty, 'message': '这首酷我录音需要音源账号授权。'}
        if info['duration'] < 60:
            return {**empty, 'message': '酷我当前仅提供短片段，无法完整播放。'}
        address = _fetch(RESOLVE, {'type': 'convert_url', 'rid': 'MUSIC_' + identity,
                                   'format': 'mp3', 'response': 'url'}, maximum=8192).strip()
        rate, size = _probe(address, info['duration'])
        return {'url': address, 'br': rate, 'size': size}
    except KuwoError as error:
        return {**empty, 'message': str(error)}


def pic(identity, size):
    identity = _id(identity)
    try:
        info = _info(identity).get('songinfo') or {}
        address = info.get('pic', '')
        # Legacy HTTP artwork is optional; do not silently rewrite origin addresses.
        return {'url': _safe_url(address, 'image')} if address else {'url': ''}
    except (KuwoError, AttributeError):
        return {'url': ''}


def lyric(identity):
    identity = _id(identity)
    output = []
    try:
        rows = _info(identity).get('lrclist') or []
        for row in rows[:5000]:
            if not isinstance(row, dict):
                continue
            try:
                timestamp = float(row.get('time', -1))
            except (TypeError, ValueError):
                continue
            if not 0 <= timestamp < 24 * 3600:
                continue
            text = _text(row.get('lineLyric')).replace('\n', ' ').replace('\r', ' ')
            output.append(f'[{int(timestamp // 60):02d}:{timestamp % 60:05.2f}]{text}')
    except (KuwoError, TypeError):
        pass
    return {'lyric': '\n'.join(output), 'tlyric': ''}
