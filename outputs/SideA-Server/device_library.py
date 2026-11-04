"""Private, device-scoped snapshots. Recovery secrets are never stored or returned."""
import hashlib
import json
import re
import secrets
import time

from flask import abort, jsonify, request


SCHEMA = '''
    CREATE TABLE IF NOT EXISTS library_profiles(
        id TEXT PRIMARY KEY,recovery_hash TEXT UNIQUE NOT NULL,platform TEXT NOT NULL,
        active_device TEXT UNIQUE NOT NULL,revoked INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 0,data TEXT,updated INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS library_devices(
        device TEXT PRIMARY KEY,profile TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS library_devices_profile ON library_devices(profile);
'''


def recovery_claim(raw, optional=False):
    if optional and 'recovery' not in raw and 'platform' not in raw:
        return None
    recovery, platform = raw.get('recovery'), raw.get('platform')
    if not isinstance(recovery, str) or not re.fullmatch('[0-9a-f]{64}', recovery):
        abort(400, description='设备恢复凭据无效。')
    if platform not in ('ios', 'android'):
        abort(400, description='设备平台无效。')
    return hashlib.sha256(recovery.encode()).hexdigest(), platform


def find_profile(db, claim):
    if claim is None:
        return None
    profile = db.execute('SELECT * FROM library_profiles WHERE recovery_hash=?', (claim[0],)).fetchone()
    if profile and (profile['revoked'] or profile['platform'] != claim[1]):
        abort(403, description='此设备资料不可恢复。')
    return profile


def check_binding(db, device, profile):
    binding = db.execute('SELECT profile FROM library_devices WHERE device=?', (device,)).fetchone()
    if binding and (profile is None or binding['profile'] != profile['id']):
        abort(403, description='此设备已绑定自己的资料。')


def attach_profile(db, device, profile, now):
    """Caller holds BEGIN IMMEDIATE and has authenticated the current device."""
    check_binding(db, device, profile)
    previous = profile['active_device']
    if previous != device:
        # Keep enrollment and binding tombstones. Retired installs cannot reenroll.
        db.execute('DELETE FROM devices WHERE id=?', (previous,))
        db.execute('UPDATE library_profiles SET active_device=?,updated=? WHERE id=?',
                   (device, now, profile['id']))
    db.execute('INSERT OR IGNORE INTO library_devices VALUES(?,?)', (device, profile['id']))


def revoke_profile(db, device):
    binding = db.execute('SELECT profile FROM library_devices WHERE device=?', (device,)).fetchone()
    if binding:
        db.execute('UPDATE library_profiles SET revoked=1 WHERE id=?', (binding['profile'],))
        db.execute('DELETE FROM devices WHERE id IN (SELECT device FROM library_devices WHERE profile=?)',
                   (binding['profile'],))


def envelope(profile):
    return {'revision': profile['revision'], 'data': json.loads(profile['data']) if profile['data'] else None}


def register_routes(app, sql, device_auth):
    @app.before_request
    def library_body_limit():
        if request.path == '/v1/library' and request.method == 'PUT':
            request.max_content_length = 4 * 1024 * 1024

    def payload():
        if request.args:
            abort(400, description='设备资料接口不接受查询参数。')
        try:
            raw = request.get_json(silent=True)
        except (RecursionError, ValueError):
            abort(400, description='设备资料格式无效。')
        if not isinstance(raw, dict):
            abort(400, description='需要 JSON 设备资料。')
        return raw

    def own_profile(db, device):
        profile = db.execute('SELECT p.* FROM library_profiles p JOIN library_devices b ON b.profile=p.id '
                             'WHERE b.device=?', (device,)).fetchone()
        if profile is None:
            abort(409, description='设备资料尚未连接。')
        if profile['revoked'] or profile['active_device'] != device:
            abort(403, description='此设备资料不可访问。')
        return profile

    @app.post('/v1/library/bind')
    def bind_library():
        device_auth()
        raw = payload()
        if set(raw) != {'recovery', 'platform'}:
            abort(400, description='设备恢复请求格式无效。')
        claim = recovery_claim(raw)
        now = int(time.time())
        with sql() as db:
            db.execute('BEGIN IMMEDIATE')
            device = device_auth(touch=False)
            profile = find_profile(db, claim)
            check_binding(db, device, profile)
            if profile is None:
                identity = secrets.token_hex(16)
                db.execute('INSERT INTO library_profiles(id,recovery_hash,platform,active_device,updated) '
                           'VALUES(?,?,?,?,?)', (identity, claim[0], claim[1], device, now))
                profile = db.execute('SELECT * FROM library_profiles WHERE id=?', (identity,)).fetchone()
            attach_profile(db, device, profile, now)
            return jsonify(envelope(profile))

    @app.get('/v1/library')
    def get_library():
        if request.args:
            abort(400, description='设备资料接口不接受查询参数。')
        with sql() as db:
            db.execute('BEGIN')
            device = device_auth(touch=False)
            return jsonify(envelope(own_profile(db, device)))

    @app.put('/v1/library')
    def put_library():
        device_auth()
        raw = payload()
        if (set(raw) != {'revision', 'data'} or type(raw.get('revision')) is not int
                or not 0 <= raw['revision'] < 2 ** 53 or not isinstance(raw.get('data'), dict)):
            abort(400, description='设备资料格式无效。')
        try:
            # Bound nesting as well as bytes, and reject non-JSON NaN/Infinity values.
            pending = [(raw['data'], 0)]
            while pending:
                value, depth = pending.pop()
                if depth > 64:
                    raise ValueError('nested document')
                if isinstance(value, dict):
                    pending.extend((child, depth + 1) for child in value.values())
                elif isinstance(value, list):
                    pending.extend((child, depth + 1) for child in value)
            encoded = json.dumps(raw['data'], ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)
            encoded.encode('utf-8')
        except (RecursionError, ValueError, TypeError, UnicodeError):
            abort(400, description='设备资料格式无效。')
        with sql() as db:
            db.execute('BEGIN IMMEDIATE')
            device = device_auth(touch=False)
            profile = own_profile(db, device)
            current = profile['revision']
            if encoded == profile['data'] and raw['revision'] in (current, current - 1):
                return jsonify(envelope(profile))
            if raw['revision'] != current:
                return jsonify(envelope(profile)), 409
            db.execute('UPDATE library_profiles SET data=?,revision=revision+1,updated=? WHERE id=?',
                       (encoded, int(time.time()), profile['id']))
            return jsonify(revision=current + 1, data=raw['data'])
