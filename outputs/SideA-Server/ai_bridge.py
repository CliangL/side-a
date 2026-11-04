"""Authenticated music-to-AI bridge. No vendor credential or model name reaches clients."""
import json
import os
import re
from urllib.parse import urlsplit

import requests
from flask import abort, jsonify, request


def register_routes(app, sql, device_auth):
    base = os.environ.get('SIDEA_AI_HUB_URL', '').rstrip('/')
    key = os.environ.get('SIDEA_AI_HUB_KEY', '')
    if base:
        target = urlsplit(base)
        if (target.username or target.password or target.query or target.fragment or
                not (target.scheme == 'https' or (target.scheme == 'http' and target.hostname in ('127.0.0.1', 'localhost')))):
            raise ValueError('AI Hub must use HTTPS or loopback HTTP')

    @app.before_request
    def ai_body_limit():
        if request.path == '/v1/ai/recommend':
            request.max_content_length = 128 * 1024

    def subject():
        device = device_auth()
        row = sql().execute('SELECT p.id,p.revoked,p.active_device FROM library_profiles p '
                            'JOIN library_devices d ON d.profile=p.id WHERE d.device=?', (device,)).fetchone()
        if not row or row['revoked'] or row['active_device'] != device:
            abort(409, description='设备资料尚未连接。')
        return 'library-' + row['id']

    def call(method, path, body=None, params=None):
        if not base or not key:
            return jsonify(ok=False, error={'code': 'model_unconfigured'}), 503
        try:
            with requests.request(method, base + path, json=body, params=params,
                                  headers={'Authorization': 'Bearer ' + key},
                                  timeout=(3, 8), allow_redirects=False, stream=True) as response:
                # Never relay provider errors, headers or secrets to an installation.
                if not 200 <= response.status_code < 300:
                    status = response.status_code if response.status_code in (404, 409, 429) else 503
                    return jsonify(ok=False, error={'code': 'ai_unavailable'}), status
                raw = bytearray()
                for chunk in response.iter_content(8192):
                    raw.extend(chunk)
                    if len(raw) > 64 * 1024:
                        raise ValueError('oversized result')
                reply = json.loads(raw)
                if path == '/v1/config':
                    config = reply.get('config', {})
                    if not isinstance(config, dict) or type(config.get('enabled')) is not bool or not re.fullmatch('[0-9a-f]{64}', str(config.get('revision', ''))):
                        raise ValueError('invalid configuration')
                    return jsonify(ok=True, config={'revision': config['revision'], 'enabled': config['enabled']})
                task = reply['task']
                if not isinstance(task, dict):
                    raise ValueError('invalid result')
                safe = {k: task[k] for k in ('id', 'status', 'result', 'cached') if k in task}
                return jsonify(ok=True, task=safe)
        except (requests.RequestException, ValueError, TypeError, KeyError):
            return jsonify(ok=False, error={'code': 'ai_unavailable'}), 503

    @app.get('/v1/ai/config')
    def configuration():
        device_auth()
        if request.args:
            abort(400)
        return call('GET', '/v1/config')

    @app.post('/v1/ai/recommend')
    def recommend():
        identity = subject()
        raw = request.get_json(silent=True)
        if request.args or not isinstance(raw, dict) or set(raw) != {'profile', 'candidates'}:
            abort(400)
        profile, candidates = raw['profile'], raw['candidates']
        try:
            profile_text = json.dumps(profile, ensure_ascii=False, allow_nan=False)
        except (ValueError, TypeError, RecursionError):
            abort(400)
        if not isinstance(profile, dict) or len(profile_text) > 6000:
            abort(400)
        if not isinstance(candidates, list) or not 1 <= len(candidates) <= 60:
            abort(400)
        seen = set()
        for item in candidates:
            if not isinstance(item, dict) or set(item) - {'id', 'title', 'artist', 'album'}:
                abort(400)
            if not re.fullmatch('[0-9a-f]{64}', str(item.get('id', ''))) or item['id'] in seen:
                abort(400)
            seen.add(item['id'])
            for field in ('title', 'artist', 'album'):
                value = item.get(field, '')
                if not isinstance(value, str) or len(value) > 200 or (field != 'album' and not value):
                    abort(400)
        # Cap actual UTF-8 payload, not just Python character count. Long Chinese
        # titles should reduce the candidate pool rather than exceed the model's
        # conservative 32k input budget (which includes prompts and envelope).
        candidates = [{k: v if k == 'id' else v[:80] for k, v in item.items()} for item in candidates]
        payload = {'profile': profile, 'candidates': candidates, 'limit': min(24, len(candidates))}
        try:
            while len(candidates) > 1 and len(json.dumps(payload, ensure_ascii=False).encode('utf-8')) > 28000:
                candidates.pop()
                payload['limit'] = min(24, len(candidates))
            if len(json.dumps(payload, ensure_ascii=False).encode('utf-8')) > 28000:
                abort(400)
        except UnicodeError:
            abort(400)
        # Hub deduplication includes the assigned model revision. A client cannot
        # know that revision, so it must not pin a stale idempotency key across a model switch.
        return call('POST', '/v1/tasks', {'subject': identity, 'capability': 'music.recommend.v1',
                                        'input': payload})

    @app.get('/v1/ai/tasks/<task_id>')
    def task(task_id):
        identity = subject()
        if request.args or not re.fullmatch('[a-zA-Z0-9_-]{1,80}', task_id):
            abort(400)
        return call('GET', '/v1/tasks/' + task_id, params={'subject': identity})

    @app.post('/v1/ai/tasks/<task_id>/cancel')
    def cancel_task(task_id):
        identity = subject()
        if request.args or request.get_json(silent=True) != {} or not re.fullmatch('[a-zA-Z0-9_-]{1,80}', task_id):
            abort(400)
        return call('POST', '/v1/tasks/' + task_id + '/cancel', {'subject': identity})
