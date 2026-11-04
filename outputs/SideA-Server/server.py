"""Private Side A controller. Phones authenticate here; media is served by its origin."""
import functools
import hashlib
import hmac
import json
import os
import re
import secrets
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import urlsplit

from flask import Flask, abort, flash, g, jsonify, redirect, render_template, request, session, url_for
from werkzeug.exceptions import HTTPException

import catalog
import device_library
import ai_bridge
from qq_provider import QQProvider, ProviderError

def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def private_secret(directory, name):
    file = directory / name
    if not file.exists():
        # The server expects one process with a thread pool. Never replace an existing key.
        try:
            fd = os.open(file,os.O_WRONLY | os.O_CREAT | os.O_EXCL,0o600)
            with os.fdopen(fd,'w') as out: out.write(secrets.token_urlsafe(32)+'\n')
        except FileExistsError: pass
    return file.read_text().strip()


def make_app(directory=None, qq=None):
    directory = Path(directory or os.environ.get('SIDEA_STATE','./data')).resolve()
    directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    dbpath = directory/'control.sqlite3'
    session_key = private_secret(directory,'session-key')
    admin_password = private_secret(directory,'admin-password')
    enrollment_key = private_secret(directory,'enrollment-key').encode()
    # Only hashes of tickets issued with the owner's private installers are deployed.
    manifest = directory/'private-builds.json'
    builds = {}
    if manifest.exists():
        for entry in json.loads(manifest.read_text()):
            ticket, capacity = entry['ticket_hash'], entry['device_limit']
            if not re.fullmatch('[0-9a-f]{64}',ticket) or type(capacity) is not int or not 1<=capacity<=100:
                raise ValueError('自用安装包配置无效')
            builds[ticket] = capacity
    with sqlite3.connect(dbpath) as db:
        db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY,val INTEGER NOT NULL);
            INSERT OR IGNORE INTO settings VALUES('revision',1);
            INSERT OR IGNORE INTO settings VALUES('auto_enrollment',1);
            CREATE TABLE IF NOT EXISTS providers(id TEXT PRIMARY KEY,name TEXT NOT NULL,kind TEXT NOT NULL,
                endpoint TEXT NOT NULL,code TEXT NOT NULL,priority INTEGER NOT NULL,enabled INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS invites(hash TEXT PRIMARY KEY,expires INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS devices(id TEXT PRIMARY KEY,name TEXT NOT NULL,
                hash TEXT UNIQUE NOT NULL,created INTEGER NOT NULL,seen INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS enrollments(installation TEXT PRIMARY KEY,
                ticket TEXT NOT NULL,device TEXT UNIQUE NOT NULL);
        ''')
        db.executescript(device_library.SCHEMA)
        for item in [('qq','QQ 音乐','qq','','tencent',10,1),
                     ('wy','网易云音乐','gd',catalog.GD,'netease',20,1),
                     ('kw','酷我音乐','kuwo','','kuwo',25,1),
                     ('jx','JOOX','gd',catalog.GD,'joox',30,1)]:
            db.execute("INSERT OR IGNORE INTO providers VALUES(?,?,?,?,?,?,?)",item)
        for identity,previous,current in [('wy','网易云音乐（GD）','网易云音乐'),('jx','JOOX（GD）','JOOX')]:
            db.execute('UPDATE providers SET name=? WHERE id=? AND name=?',(current,identity,previous))
    dbpath.chmod(0o600)
    app = Flask(__name__)
    app.config.update(SECRET_KEY=session_key, MAX_CONTENT_LENGTH=16384, SESSION_COOKIE_NAME='sidea_admin',
                      SESSION_COOKIE_HTTPONLY=True,SESSION_COOKIE_SECURE=True,SESSION_COOKIE_SAMESITE='Strict')
    # Outside URLs and any proxy mount point belong to the deployment, not the HTTP client.
    public_base = os.environ.get('SIDEA_PUBLIC_BASE','').rstrip('/')
    if public_base:
        target = urlsplit(public_base)
        if target.scheme!='https' or not target.hostname or target.username or target.password or target.query or target.fragment:
            raise ValueError('SIDEA_PUBLIC_BASE 必须是此服务对手机公开的 HTTPS 地址')
        dispatch = app.wsgi_app
        def mounted(environ,start_response):
            environ['wsgi.url_scheme']='https'
            environ['HTTP_HOST']=target.netloc
            environ['SCRIPT_NAME']=target.path.rstrip('/')
            return dispatch(environ,start_response)
        app.wsgi_app=mounted
        app.jinja_env.globals['public_base']=public_base
        app.config['SESSION_COOKIE_PATH']=target.path.rstrip('/') or '/'
    qq = qq if qq is not None else QQProvider(directory)
    app.extensions['sidea_qq'] = qq
    throttles={}
    lock=threading.Lock()

    def sql():
        if 'db' not in g:
            g.db=sqlite3.connect(dbpath,timeout=10)
            g.db.row_factory=sqlite3.Row
        return g.db

    @app.teardown_appcontext
    def close_db(_):
        if 'db' in g:g.db.close()

    def revision():
        return sql().execute("SELECT val FROM settings WHERE key='revision'").fetchone()[0]

    def bump():
        sql().execute("UPDATE settings SET val=val+1 WHERE key='revision'")

    def limit(group, maximum, seconds):
        # One private owner. Keep limits bounded even with untrusted forwarded headers.
        key=(group, request.remote_addr)
        now=time.monotonic()
        with lock:
            if len(throttles)>1000:
                for k in list(throttles):
                    if not throttles[k] or now-throttles[k][-1]>600:del throttles[k]
            hits=[t for t in throttles.get(key,[]) if t>now-seconds]
            if len(hits)>=maximum:abort(429,description='尝试较多，请稍后再试。')
            hits.append(now)
            throttles[key]=hits

    def csrf():
        if 'csrf' not in session:session['csrf']=secrets.token_urlsafe(24)
        return session['csrf']

    app.jinja_env.globals.update(csrf=csrf)

    def admin(function):
        @functools.wraps(function)
        def checked(*args,**kwargs):
            if not session.get('owner'):
                if request.path.startswith('/admin/qq/') and (request.method=='GET' or request.path.endswith('/login')):abort(401)
                return redirect(url_for('login'))
            if request.method=='POST' and not secrets.compare_digest(request.form.get('csrf',''),csrf()):abort(403)
            return function(*args,**kwargs)
        return checked

    @app.after_request
    def headers(resp):
        resp.headers.update({'Cache-Control':'no-store','X-Content-Type-Options':'nosniff',
                             'Referrer-Policy':'no-referrer','X-Frame-Options':'DENY'})
        return resp

    @app.errorhandler(HTTPException)
    def http_error(e):
        if request.path.startswith('/v1/') or request.path.startswith('/admin/qq/'):
            return jsonify(error=str(e.description)[:200]), e.code
        return render_template('error.html',message=e.description), e.code

    @app.errorhandler(catalog.CatalogError)
    @app.errorhandler(ProviderError)
    def provider_error(e):
        if request.path.startswith('/v1/') or request.path.startswith('/admin/qq/'):
            return jsonify(error=str(e)[:180]),502
        flash(str(e)[:180]);return redirect(url_for('home'))

    @app.get('/health')
    def health():return jsonify(service='Side A',ok=True)

    @app.route('/login',methods=['GET','POST'])
    def login():
        if request.method=='POST':
            limit('login',12,300)
            if not secrets.compare_digest(request.form.get('csrf',''),csrf()):abort(403)
            if secrets.compare_digest(digest(request.form.get('password','')),digest(admin_password)):
                session.clear();session['owner']=True
                return redirect(url_for('home'))
            flash('管理员密码不正确。')
        return render_template('login.html')

    @app.post('/admin/logout')
    @admin
    def logout():session.clear();return redirect(url_for('login'))

    @app.get('/')
    @admin
    def home():
        providers=sql().execute('SELECT * FROM providers ORDER BY priority,id').fetchall()
        devices=sql().execute('SELECT id,name,created,seen FROM devices ORDER BY created DESC').fetchall()
        auto_enabled=bool(sql().execute("SELECT val FROM settings WHERE key='auto_enrollment'").fetchone()[0])
        return render_template('admin.html',providers=providers,devices=devices,revision=revision(),qq=qq.status(),
                               private_builds=bool(builds),auto_enabled=auto_enabled,
                               issued=session.pop('new_invite',None))

    @app.post('/admin/invite')
    @admin
    def invite():
        now=int(time.time());code=secrets.token_hex(5).upper()
        with sql() as db:
            db.execute('DELETE FROM invites WHERE expires<=?',(now,))
            db.execute('INSERT INTO invites VALUES(?,?)',(digest(code),now+600))
        session['new_invite']=code
        return redirect(url_for('home'))

    @app.post('/admin/enrollment')
    @admin
    def enrollment_setting():
        enabled=request.form.get('enabled')=='1'
        with sql() as db:
            db.execute("UPDATE settings SET val=? WHERE key='auto_enrollment'",(int(enabled),))
        return redirect(url_for('home'))

    @app.post('/v1/enroll')
    def auto_enroll():
        authorization=request.headers.get('Authorization','')
        match=re.fullmatch(r'SideA-Setup ([A-Za-z0-9_-]{43})',authorization)
        if not match:abort(403)
        ticket=digest(match[1])
        if ticket not in builds:abort(403)
        limit('enroll',80,300)
        raw=request.get_json(silent=True)
        if not isinstance(raw,dict):abort(400)
        name=raw.get('name'); installation=raw.get('installation')
        if not isinstance(name,str) or not name.strip() or len(name)>80 or not isinstance(installation,str):abort(400)
        try: identity=uuid.UUID(installation)
        except ValueError:abort(400)
        if identity.version!=4 or str(identity)!=installation:abort(400)
        recovery=device_library.recovery_claim(raw,optional=True)
        install_hash=digest(installation)
        token=hmac.new(enrollment_key,identity.bytes,hashlib.sha256).hexdigest()
        now=int(time.time())
        with sql() as db:
            db.execute('BEGIN IMMEDIATE')
            known=db.execute('SELECT device FROM enrollments WHERE installation=?',(install_hash,)).fetchone()
            profile=device_library.find_profile(db,recovery)
            if known:
                # Revoking a device deletes its bearer but retains this enrollment.
                if not db.execute('SELECT 1 FROM devices WHERE id=? AND hash=?',(known[0],digest(token))).fetchone():
                    abort(403,description='这台设备已被撤销。')
                if recovery:
                    device_library.check_binding(db,known[0],profile)
                if profile:
                    device_library.attach_profile(db,known[0],profile,now)
                return jsonify(token=token),200
            if not profile and not db.execute("SELECT val FROM settings WHERE key='auto_enrollment'").fetchone()[0]:abort(403)
            used=db.execute('SELECT count(*) FROM enrollments e JOIN devices d ON d.id=e.device WHERE e.ticket=?',
                            (ticket,)).fetchone()[0]
            if not profile and used>=builds[ticket]:abort(403,description='此自用安装包的设备名额已用完。')
            device=secrets.token_hex(8)
            db.execute('INSERT INTO devices VALUES(?,?,?,?,?)',(device,name.strip(),digest(token),now,now))
            db.execute('INSERT INTO enrollments VALUES(?,?,?)',(install_hash,ticket,device))
            if profile:
                device_library.attach_profile(db,device,profile,now)
        return jsonify(token=token),201

    @app.post('/v1/pair')
    def pair():
        limit('pair',25,300)
        raw=request.get_json(silent=True)
        if not isinstance(raw,dict):abort(400,description='需要 JSON 配对请求。')
        name=raw.get('name'); code=raw.get('code')
        if not isinstance(name,str) or not name.strip() or len(name)>80 or not isinstance(code,str):
            abort(400,description='请填写设备名称和配对码。')
        now=int(time.time()); token=secrets.token_urlsafe(32)
        with sql() as db:
            db.execute('BEGIN IMMEDIATE')
            claim=db.execute('DELETE FROM invites WHERE hash=? AND expires>?',(digest(code.strip().replace('-','').upper()),now))
            if claim.rowcount!=1:abort(403,description='配对码不正确、已用过或已过期。')
            db.execute('INSERT INTO devices VALUES(?,?,?,?,?)',(secrets.token_hex(8),name.strip(),digest(token),now,now))
        return jsonify(token=token),201

    @app.post('/admin/devices/<device>/revoke')
    @admin
    def revoke(device):
        with sql() as db:
            db.execute('BEGIN IMMEDIATE')
            device_library.revoke_profile(db,device)
            db.execute('DELETE FROM devices WHERE id=?',(device,))
        flash('该设备已撤销，下次请求会被拒绝。')
        return redirect(url_for('home'))

    @app.post('/admin/providers/add')
    @admin
    def add():
        name=request.form.get('name','').strip();code=request.form.get('code','').strip().lower()
        if not name or len(name)>50 or not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}',code):
            abort(400,description='名称或 source 代码无效。')
        endpoint=catalog.trusted_endpoint(request.form.get('endpoint','').strip())
        with sql() as db:
            if db.execute('SELECT count(*) FROM providers').fetchone()[0]>=16:
                abort(400,description='最多可配置 16 个来源。')
            if db.execute('SELECT 1 FROM providers WHERE endpoint=? AND code=?',(endpoint,code)).fetchone():
                abort(409,description='已配置相同接口及来源。')
            db.execute('INSERT INTO providers VALUES(?,?,?,?,?,?,?)',(secrets.token_hex(8),name,'gd',endpoint,code,100,1)); bump()
        flash('已加入统一曲库。');return redirect(url_for('home'))

    @app.post('/admin/providers/<provider>/update')
    @admin
    def update(provider):
        name=request.form.get('name','').strip()
        try:priority=int(request.form.get('priority',''))
        except ValueError:abort(400,description='请输入整数顺序。')
        if not name or len(name)>50 or priority not in range(0,1000):abort(400,description='来源名称或顺序无效。')
        with sql() as db:
            result=db.execute('UPDATE providers SET name=?,enabled=?,priority=? WHERE id=?',
                              (name,1 if request.form.get('enabled')=='on' else 0,priority,provider))
            if result.rowcount!=1:abort(404)
            bump()
        flash('已发布，设备下次搜索使用新配置。');return redirect(url_for('home'))

    @app.post('/admin/providers/<provider>/remove')
    @admin
    def remove(provider):
        if provider in ('qq','wy','jx','kw'):abort(400,description='内置来源可以停用。')
        with sql() as db:
            db.execute('DELETE FROM providers WHERE id=?',(provider,));bump()
        return redirect(url_for('home'))

    @app.post('/admin/qq/login')
    @admin
    def qq_login():
        method=request.form.get('method','qq')
        if method not in ('qq','mobile'):abort(400,description='请使用手机 QQ 或 QQ 音乐扫码。')
        limit('qr',10,300)
        return jsonify(qq.start_login(method))

    @app.get('/admin/qq/status/<attempt>')
    @admin
    def qq_status(attempt):return jsonify(qq.login_status(attempt))

    @app.post('/admin/qq/unlink')
    @admin
    def unlink():
        qq.logout()
        with sql():bump()
        flash('已断开后台的 QQ 登录。');return redirect(url_for('home'))

    def device_auth(touch=True):
        authorization=request.headers.get('Authorization','')
        if not authorization.startswith('Bearer ') or len(authorization)>180:abort(401,description='请先配对统一后台。')
        row=sql().execute('SELECT id,seen FROM devices WHERE hash=?',(digest(authorization[7:]),)).fetchone()
        if not row:abort(401,description='设备已被撤销，请重新配对。')
        now=int(time.time())
        if touch and now-row['seen']>=60:
            with sql():sql().execute('UPDATE devices SET seen=? WHERE id=?',(now,row['id']))
        return row['id']

    device_library.register_routes(app,sql,device_auth)
    ai_bridge.register_routes(app,sql,device_auth)

    @app.get('/v1/music')
    def music():
        device_auth()
        q=request.args
        if q.get('source')!='central':abort(400,description='统一后台的 source 是 central。')
        kind=q.get('types')
        if kind=='search':
            term=q.get('name','').strip()
            if not term or len(term)>150:abort(400,description='关键词无效。')
            try:page=int(q.get('pages','1')); count=int(q.get('count','25'))
            except ValueError:abort(400)
            if not 1<=page<=100 or not 1<=count<=50:abort(400)
            filters=q.getlist('provider')
            if filters:
                if len(filters)!=1 or not re.fullmatch('[a-z0-9]{1,64}',filters[0]):
                    abort(400,description='曲库标识无效。')
                sources=sql().execute('SELECT * FROM providers WHERE enabled=1 AND id=?',filters).fetchall()
                if not sources:abort(404,description='此曲库已停用或不存在。')
            else:
                sources=sql().execute('SELECT * FROM providers WHERE enabled=1 ORDER BY priority,id').fetchall()
            return jsonify(catalog.search(sources,term,page,count,revision(),qq))
        if kind not in ('url','lyric','pic'):abort(400)
        identifier=q.get('id','')
        if len(identifier)>1600:abort(400)
        provider,raw=catalog.unpack(identifier)
        found=sql().execute('SELECT * FROM providers WHERE enabled=1 AND id=?',(provider,)).fetchone()
        if not found:abort(404,description='此来源已被管理员停用或移除。')
        try:br=int(q.get('br',320)); size=int(q.get('size',500))
        except ValueError:abort(400)
        if br not in (128,192,320,740,999) or size not in (300,500):abort(400)
        return jsonify(catalog.detail(found,kind,raw,br,size,qq))
    return app
