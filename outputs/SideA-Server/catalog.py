"""Central catalog IDs are independent of provider names and sort order."""
import base64
import concurrent.futures
import ipaddress
import json
import socket
import threading
import time
from urllib.parse import urlsplit

import requests
import kuwo_provider

GD = "https://music-api.gdstudio.xyz/api.php"
workers = concurrent.futures.ThreadPoolExecutor(max_workers=8)
guard = threading.Lock()
search_cache = {}
rate_window = []


class CatalogError(Exception):
    pass


def trusted_endpoint(raw):
    try:
        parts = urlsplit(raw)
        if (parts.scheme != 'https' or not parts.hostname or parts.username is not None or
                parts.password is not None or parts.query or parts.fragment or
                any(c.isspace() for c in raw)):
            raise ValueError()
        port = parts.port or 443
        if not all(ipaddress.ip_address(x[4][0]).is_global for x in socket.getaddrinfo(parts.hostname, port)):
            raise ValueError()
    except (ValueError, OSError):
        raise CatalogError("接口必须使用可公开访问的 HTTPS 地址，不能带登录信息或查询参数。")
    return raw


def pack(source, value):
    value = str(value or '')
    if not value:
        return ''
    return source + "." + base64.urlsafe_b64encode(value.encode()).decode().rstrip('=')


def unpack(key):
    try:
        source, encoded = key.split('.', 1)
        raw = base64.b64decode(encoded + '=' * (-len(encoded) % 4), altchars=b'-_', validate=True).decode()
        if not raw or len(raw) > 1024 or pack(source, raw) != key:
            raise ValueError()
        return source, raw
    except (ValueError, UnicodeError):
        raise CatalogError("曲目编号无效。")


def call_gd(provider, args):
    endpoint = trusted_endpoint(provider['endpoint'])
    if endpoint == GD:
        with guard:
            now = time.monotonic()
            rate_window[:] = [t for t in rate_window if t > now-300]
            if len(rate_window) >= (50 if args['types'] == 'url' else 44):
                raise CatalogError("GD 曲库请求较频繁，请稍后再试。")
            rate_window.append(now)
    params = {**args, 'source': provider['code']}
    headers = {'User-Agent':'SideA/0.4', 'Referer':'https://music.gdstudio.xyz/' if endpoint == GD else
               'https://' + urlsplit(endpoint).netloc + '/'}
    try:
        with requests.get(endpoint, params=params, headers=headers, allow_redirects=False, stream=True, timeout=(3,7)) as r:
            if r.status_code != 200:
                raise CatalogError("曲库未能响应，请稍后重试。")
            buf = bytearray()
            for chunk in r.iter_content(16384):
                buf.extend(chunk)
                if len(buf) > 1536 * 1024:
                    raise CatalogError("曲库返回的数据过大。")
        return json.loads(buf)
    except (requests.RequestException, ValueError):
        raise CatalogError("曲库暂时无法连接。")


def search_one(provider, query, page, count, revision, qq):
    cachekey = (revision,provider['id'],query,page,count)
    with guard:
        cached = search_cache.get(cachekey)
        if cached and cached[0] > time.monotonic():
            return cached[1]
    if provider['kind'] == 'qq':
        raw = qq.search(query,page,count)
    elif provider['kind'] == 'kuwo':
        raw = kuwo_provider.search(query,page,count)
    else:
        raw = call_gd(provider, {'types':'search','name':query,'pages':page,'count':count})
    if not isinstance(raw,list):
        raise CatalogError("曲库没有返回歌曲列表。")
    rows, seen = [], set()
    for row in raw[:count]:
        if not isinstance(row,dict) or str(row.get('source','')).lower() != provider['code']:
            continue
        track = str(row.get('id') or '')
        if not track or track in seen or not row.get('name') or len(track)>1024:
            continue
        seen.add(track)
        rows.append({'id':pack(provider['id'],track),'name':str(row['name']),
                     'artist':row.get('artist') or [],'album':row.get('album') or '',
                     'pic_id':pack(provider['id'],row.get('pic_id')),
                     'lyric_id':pack(provider['id'],row.get('lyric_id') or track),
                     'source':'central','provider_id':provider['id'],'provider_name':provider['name']})
    with guard:
        if len(search_cache)>=256: search_cache.clear()
        search_cache[cachekey]=(time.monotonic()+30,rows)
    return rows


def search(providers, query, page, count, revision, qq):
    if not providers:
        raise CatalogError("管理员尚未启用曲库。")
    pending = [workers.submit(search_one,p,query,page,count,revision,qq) for p in providers]
    results, failures = [], []
    for provider,future in zip(providers,pending):
        try: results.extend(future.result())
        except Exception: failures.append(provider['name'])
    if len(failures)==len(providers):
        raise CatalogError("暂时无法查询：" + "、".join(failures))
    return results


def detail(provider, kind, raw, br, size, qq):
    if provider['kind']=='qq':
        if kind=='url': result=qq.url(raw,br)
        elif kind=='pic': result=qq.pic(raw,size)
        else: result=qq.lyric(raw)
    elif provider['kind']=='kuwo':
        try:
            if kind=='url': result=kuwo_provider.url(raw,br)
            elif kind=='pic': result=kuwo_provider.pic(raw,size)
            else: result=kuwo_provider.lyric(raw)
        except kuwo_provider.KuwoError as error:
            raise CatalogError(str(error)) from None
    else:
        args={'types':kind,'id':raw}
        if kind=='url': args['br']=br
        if kind=='pic': args['size']=size
        result=call_gd(provider,args)
    if not isinstance(result,dict):
        raise CatalogError("曲库未能返回可用资料。")
    if kind=='lyric':
        return {k:str(result.get(k) or '') for k in ('lyric','tlyric')}
    address=str(result.get('url') or '')
    if address:
        u=urlsplit(address)
        if u.scheme not in ('http','https') or not u.hostname or u.username or u.password:
            address=''
        elif u.scheme=='http':
            address='https'+address[4:]
    if kind=='pic': return {'url':address}
    try: rate,maxsize = int(result.get('br') or 0),int(result.get('size') or 0)
    except (TypeError,ValueError): rate,maxsize=0,0
    return {'url':address,'br':rate if address else 0,'size':maxsize if address else 0,
            'message':str(result.get('message') or '')[:160] if not address else ''}
