"""Owner-only QQ connector for the Side A controller (Python 3.12)."""
import asyncio
import base64
from concurrent.futures import TimeoutError as FutureTimeout
from contextlib import aclosing, suppress
from contextvars import ContextVar
import html
import json
import logging
import os
from pathlib import Path
import re
import secrets
import tempfile
import threading
import time
from urllib.parse import urlencode, urljoin, urlsplit, urlunsplit
from urllib.request import Request, urlopen

from cryptography.fernet import Fernet
from qqmusic_api import Client, Credential, CredentialExpiredError, CredentialRefreshError, LoginError
from qqmusic_api.core.exceptions import NetworkError
from qqmusic_api.core.transport import NiquestsTransport
from qqmusic_api.models.login import QRCodeLoginEvents, QRLoginType
from qqmusic_api.modules.song import SongFileInfo, SongFileType


class ProviderError(RuntimeError):
    """Message is suitable for display and contains no returned URLs or credentials."""


# The transport feeds the unchanged SDK and is local to this connector. QQ sometimes
# sends an empty ETK on successful confirmation. niquests 3.x raises KeyError
# when that cookie is looked up by name, but its items() retains the original value.
_AUTH_STAGES = {
    "https://ssl.ptlogin2.qq.com/ptqrshow": "qr-create",
    "https://ssl.ptlogin2.qq.com/ptqrlogin": "qr-poll",
    "https://ssl.ptlogin2.graph.qq.com/check_sig": "signature-exchange",
    "https://graph.qq.com/oauth2.0/authorize": "oauth-grant",
}
_log = logging.getLogger(__name__)
_stage = ContextVar("sidea_qq_stage", default=None)


class _AuthResponse:
    def __init__(self, response):
        self._response = response
        self.cookies = {}
        for name, value in response.cookies.items():
            previous = self.cookies.get(name)
            if previous and value and previous != value:
                # The SDK only supports a flat mapping. Never pick between
                # conflicting nonempty session values with different scopes.
                raise ProviderError("QQ 授权响应含有冲突的登录信息，请重新扫码")
            self.cookies[name] = previous or value or ""

    def __getattr__(self, name):
        return getattr(self._response, name)


class _QQTransport(NiquestsTransport):
    async def request_many(self, requests, *, return_exceptions=True):
        stages = [_AUTH_STAGES.get(req.url.partition("?")[0]) for req in requests]
        step = _stage.get()
        if step is not None and len(stages) == 1:
            step[0] = stages[0] or "music-exchange"
        outcomes = await super().request_many(requests, return_exceptions=return_exceptions)
        for i, (stage, response) in enumerate(zip(stages, outcomes)):
            if stage and not isinstance(response, Exception):
                try:
                    outcomes[i] = _AuthResponse(response)
                except ProviderError as error:
                    if not return_exceptions:
                        raise
                    outcomes[i] = error
        return outcomes


def _diagnose(stage, error):
    code = getattr(error, "code", None)
    if not isinstance(code, int):
        code = None
    _log.warning("qq_login stage=%s error=%s code=%s", stage, type(error).__name__, code)


def _mid(value):
    if not isinstance(value, str) or not re.fullmatch(r'[a-zA-Z0-9]{1,64}', value):
        raise ProviderError("歌曲或专辑 ID 无效")
    return value


def _media_url(base, path):
    parts = urlsplit(urljoin(base, path))
    host = parts.hostname or ""
    if (parts.scheme not in ("http", "https") or parts.username or parts.password or
            parts.port not in (None, 80, 443) or
            not host.endswith((".qq.com", ".gtimg.cn", ".gtimg.com", ".qpic.cn"))):
        return None
    return urlunsplit(("https", host, parts.path, parts.query, ""))


def _write_private(path, data):
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(tmp, path)
    finally:
        Path(tmp).unlink(missing_ok=True)


class QQProvider:
    """One owner and one upstream login. Clients only receive track data."""
    def __init__(self, data_dir: Path):
        self.store = Path(data_dir) / "qq"
        self.store.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.store, 0o700)
        self.auth_file = self.store / "account.enc"
        self.key_path = Path(os.environ.get("SIDEA_QQ_MASTER_KEY_FILE", self.store / "account.key"))
        self.credential = None
        self.message = "尚未绑定 QQ 音乐"
        if self.auth_file.exists():
            try:
                saved = self._cipher(create=False).decrypt(self.auth_file.read_bytes())
                self.credential = Credential.model_validate_json(saved)
                if not self.credential.is_valid():
                    raise ValueError("invalid")
                self.message = "已保存 QQ 登录状态，播放时核对权限"
            except Exception:
                self.credential = None
                self.message = "无法读取保存的登录状态，请在后台重新扫码"
        self.attempt = ""
        self.attempt_state = "expired"
        self.qr = None
        self.deadline = 0.0
        self.login_task = None
        self.login_message = ""
        self.next_account_check = 0.0
        self.slots = threading.BoundedSemaphore(5)
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, name="sidea-qq", daemon=True)
        self.thread.start()
        self.client = None
        self.lock = asyncio.Lock()

    def _cipher(self, create):
        if create and not self.key_path.exists() and "SIDEA_QQ_MASTER_KEY_FILE" not in os.environ:
            fd = os.open(self.key_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(Fernet.generate_key())
                f.flush()
                os.fsync(f.fileno())
        return Fernet(self.key_path.read_bytes().strip())

    def _save(self, credential):
        if not credential.is_valid():
            raise ProviderError("登录未返回有效凭据，请重新扫码")
        raw = credential.model_dump_json(by_alias=True).encode()
        _write_private(self.auth_file, self._cipher(create=True).encrypt(raw))
        self.credential = credential
        self.next_account_check = time.monotonic() + 600
        self.message = "已保存 QQ 登录状态，播放时核对权限"

    def _call(self, method, *args):
        if not self.slots.acquire(timeout=0.3):
            raise ProviderError("QQ 曲库繁忙，请稍后重试")
        async def execute():
            if self.client is None:
                self.client = Client(device_path=str(self.store / "device.json"), max_concurrency=3,
                                     transport=_QQTransport(max_concurrency=3))
            async with asyncio.timeout(12):
                return await method(*args)
        try:
            future = asyncio.run_coroutine_threadsafe(execute(), self.loop)
            try:
                return future.result(timeout=14)
            except FutureTimeout:
                future.cancel()
                raise ProviderError("QQ 音乐响应超时，请稍后重试") from None
            except ProviderError:
                raise
            except LoginError:
                raise ProviderError("QQ 音乐没有接受登录，请留意手机上的授权或设备限制提示") from None
            except Exception:
                raise ProviderError("QQ 音乐接口暂未返回有效数据，请稍后重试") from None
        finally:
            self.slots.release()

    def status(self):
        return self._call(self._status)

    async def _status(self):
        present = bool(self.credential and self.credential.is_valid())
        refresh_due = present and self.credential.key_expires_in and self.credential.is_expired()
        return {"connected": present and not refresh_due,
                "message": "登录已到刷新时间，将在下次播放时尝试续期" if refresh_due else self.message}

    def start_login(self, method="qq"):
        if method not in ("qq", "mobile"):
            raise ProviderError("请选择手机 QQ 或 QQ 音乐扫码")
        return self._call(self._start_login, QRLoginType(method))

    async def _stop_login(self):
        if self.login_task is not None:
            self.login_task.cancel()
            with suppress(asyncio.CancelledError):
                await self.login_task
            self.login_task = None

    async def _start_login(self, method):
        async with self.lock:
            try:
                qr = await self.client.login.get_qrcode(method)
            except Exception as error:
                _diagnose("qr-create", error)
                raise ProviderError("暂时取不到二维码，请稍后重试") from None
            looks_like_png = qr.mimetype == "image/png" and qr.data.startswith(b"\x89PNG\r\n\x1a\n")
            looks_like_jpeg = qr.mimetype == "image/jpeg" and qr.data.startswith(b"\xff\xd8\xff")
            if not (looks_like_png or looks_like_jpeg) or len(qr.data) > 256 * 1024:
                raise ProviderError("QQ 音乐未返回登录二维码")
            await self._stop_login()
            self.attempt, self.qr = secrets.token_urlsafe(24), qr
            self.deadline = self.loop.time() + 120
            self.attempt_state = "pending"
            app = "QQ 音乐" if method == QRLoginType.MOBILE else "手机 QQ"
            self.login_message = f"请用{app}扫码并确认"
            ready = asyncio.Event()
            self.login_task = asyncio.create_task(self._watch(qr, method, ready))
            if method == QRLoginType.MOBILE:
                try:
                    # Only expose the code once QQ has acknowledged the event subscription.
                    await asyncio.wait_for(ready.wait(), timeout=8)
                except (TimeoutError, asyncio.CancelledError):
                    await self._stop_login()
                    raise ProviderError("暂时连不上 QQ 音乐扫码服务，请使用手机 QQ 扫码") from None
                if self.attempt_state not in ("pending", "scanned", "connected"):
                    raise ProviderError(self.login_message)
            return {"id": self.attempt, "status": self.attempt_state, "message": f"请用{app}扫码并确认" if self.attempt_state == "pending" else self.login_message,
                    "image": f"data:{qr.mimetype};base64," + base64.b64encode(qr.data).decode("ascii")}

    async def _watch(self, qr, method, ready):
        stage = ["qr-poll"]
        token = _stage.set(stage)
        try:
            async with asyncio.timeout_at(self.deadline):
                if method == QRLoginType.MOBILE:
                    async with aclosing(self.client.login.checking_mobile_qrcode(qr, deadline=self.deadline)) as events:
                        async for event in events:
                            done = self._receive(event, stage)
                            ready.set()
                            if done:
                                return
                    raise NetworkError("mobile stream closed")
                while True:
                    try:
                        async with asyncio.timeout(min(22, self.deadline - self.loop.time())):
                            answer = await self.client.login.check_qrcode(qr)
                    except (NetworkError, TimeoutError) as error:
                        _diagnose(stage[0], error)
                        self.login_message = "QQ 连接暂时中断，后台正在继续查询同一个二维码"
                        await asyncio.sleep(3)
                        continue
                    if self._receive(answer, stage):
                        return
                    await asyncio.sleep(2)
        except TimeoutError:
            self.attempt_state, self.login_message = "expired", "二维码已过期，请获取新的二维码"
        except Exception as error:
            _diagnose(stage[0], error)
            self.attempt_state = "unavailable"
            codes = {20279: "QQ 音乐提示登录设备数已达上限，请在 QQ 音乐管理设备后重新扫码",
                     104604: "QQ 音乐提示请求过于频繁，请稍后再扫码",
                     20277: "QQ 提示账号授权受限，请查看手机提示",
                     20278: "QQ 提示账号授权受限，请查看手机提示",
                     20450: "QQ 提示当前账号受限，请查看手机提示"}
            self.login_message = codes.get(getattr(error, "code", None),
                                           "QQ 音乐未能完成授权，请获取新二维码后再试")
            if stage[0] == "credential-save":
                self.login_message = "未能安全保存登录信息，请检查后台数据目录或密钥"
        finally:
            ready.set()
            _stage.reset(token)
            self.qr = None

    def _receive(self, answer, stage):
        event = answer.event
        if event == QRCodeLoginEvents.DONE:
            stage[0] = "credential-validate"
            if not answer.credential or not answer.credential.is_valid():
                raise ProviderError("QQ 未返回有效登录凭据")
            stage[0] = "credential-save"
            self._save(answer.credential)
            self.attempt_state, self.login_message = "connected", "QQ 音乐已连接"
            return True
        labels = {QRCodeLoginEvents.SCAN: ("pending", "等待扫码"),
                  QRCodeLoginEvents.CONF: ("scanned", "已扫码，请在手机上确认"),
                  QRCodeLoginEvents.REFUSE: ("denied", "已取消授权"),
                  QRCodeLoginEvents.TIMEOUT: ("expired", "二维码已过期，请获取新的二维码")}
        self.attempt_state, self.login_message = labels[event]
        return self.attempt_state in ("denied", "expired")

    def login_status(self, attemptID):
        return self._call(self._login_status, attemptID)

    async def _login_status(self, attempt):
        if not self.attempt or not isinstance(attempt, str) or not secrets.compare_digest(attempt.encode(), self.attempt.encode()):
            return {"id": "", "status": "expired", "message": "二维码已失效"}
        return {"id": attempt, "status": self.attempt_state, "message": self.login_message}

    def logout(self):
        return self._call(self._logout)

    async def _logout(self):
        async with self.lock:
            await self._stop_login()
            self.auth_file.unlink(missing_ok=True)
            self.attempt, self.qr, self.attempt_state = "", None, "expired"
            self.credential = None
            self.message = "已解除 Side A 的 QQ 绑定"
            return await self._status()

    def search(self, query, page=1, count=20):
        query = str(query).strip()[:140]
        if not query:
            return []
        if not self.slots.acquire(timeout=0.3):
            raise ProviderError("QQ 曲库繁忙，请稍后重试")
        try:
            params = {"w":query, "format":"json", "p":max(1,int(page)), "n":min(50,max(1,int(count))),"t":0,"cr":1}
            url = "https://c.y.qq.com/soso/fcgi-bin/search_for_qq_cp?" + urlencode(params)
            request = Request(url, headers={"Referer":"https://y.qq.com/"})
            with urlopen(request,timeout=8) as r:
                result = json.loads(r.read(2_000_000))
            if result.get("code") != 0:
                raise ProviderError("QQ 搜索暂不可用")
            rows = result["data"]["song"]["list"]
            return [{"id":row["songmid"], "name":html.unescape(row["songname"]),
                     "artist":[html.unescape(a["name"]) for a in row.get("singer",[])],
                     "album":html.unescape(row.get("albumname","")), "pic_id":row.get("albummid",""),
                     "lyric_id":row["songmid"], "source":"tencent"} for row in rows if row.get("songmid")]
        except Exception:
            raise ProviderError("QQ 音乐暂未返回搜索结果，请稍后重试") from None
        finally:
            self.slots.release()

    async def _refresh(self, previous):
        async with self.lock:
            if self.credential is not previous or previous is None:
                return self.credential
            try:
                updated = await self.client.login.refresh_credential(previous)
            except (CredentialExpiredError, CredentialRefreshError, LoginError) as error:
                if getattr(error, "code", 0) in (1000, 104400, 104401):
                    self.auth_file.unlink(missing_ok=True)
                    self.credential = None
                    self.message = "QQ 登录状态已失效，请在后台重新扫码"
                    raise ProviderError(self.message) from None
                self.message = "QQ 暂未接受续期，可稍后重试或在后台重新扫码"
                raise ProviderError(self.message) from None
            self._save(updated)
            return updated

    def url(self, id, br):
        return self._call(self._url, _mid(id), int(br))

    async def _url(self, mid, br):
        qualities = {999:(SongFileType.FLAC, "size_flac"),740:(SongFileType.FLAC, "size_flac"),
                     320:(SongFileType.MP3_320, "size_320mp3"),192:(SongFileType.ACC_192, "size_192aac"),
                     128:(SongFileType.MP3_128, "size_128mp3")}
        if br not in qualities:
            raise ProviderError("不支持此音质")
        credential = self.credential
        if credential:
            expired = credential.key_expires_in and credential.is_expired()
            if not expired and time.monotonic() >= self.next_account_check:
                # Recheck a retained login periodically. A transport error does not erase it.
                expired = await self.client.login.check_expired(credential)
                if self.credential is not credential:
                    raise ProviderError("QQ 授权已更改，请重试")
                if not expired:
                    self.next_account_check = time.monotonic() + 600
            if expired:
                credential = await self._refresh(credential)
        song = (await self.client.song.get_detail(mid)).track
        fmt, size_key = qualities[br]
        size = getattr(song.file, size_key, 0)
        if not size or not song.file.media_mid:
            raise ProviderError("该录音没有所选音质的全曲文件")
        info = SongFileInfo(mid, fmt, song.type, song.file.media_mid)
        try:
            answer = await self.client.song.get_song_urls([info], credential=credential)
        except CredentialExpiredError:
            if not credential:
                raise ProviderError("该录音需要有效的 QQ 登录状态") from None
            credential = await self._refresh(credential)
            answer = await self.client.song.get_song_urls([info], credential=credential)
        for item in answer.data:
            if item.result == 104003:
                raise ProviderError("QQ 音乐未授予当前账号该录音的所选音质")
            if item.result == 104013:
                raise ProviderError("QQ 音乐提示当前播放设备受限")
            expected = fmt.s + song.file.media_mid + fmt.e
            if item.result != 0 or item.mid != mid or not item.purl or item.filename != expected:
                continue
            for base in (await self.client.song.get_cdn_dispatch()).sip:
                url = _media_url(base, item.purl)
                if url:
                    if self.credential is not credential:
                        raise ProviderError("QQ 授权已更改，请重试")
                    bitrate = round(size * 8 / (song.interval * 1000)) if br in (740,999) and song.interval else br
                    return {"url":url, "br":bitrate, "size":size}
        raise ProviderError("QQ 音乐未返回该录音的完整播放地址")

    def pic(self, id, size=500):
        mid = _mid(id)
        return {"url":f"https://y.gtimg.cn/music/photo_new/T002R{300 if int(size)<=300 else 500}x{300 if int(size)<=300 else 500}M000{mid}.jpg"}

    def lyric(self, id):
        return self._call(self._lyric, _mid(id))

    async def _lyric(self, mid):
        record = await self.client.lyric.get_lyric(mid, trans=True)
        return {"lyric":record.lyric, "tlyric":record.trans}

    async def _close(self):
        await self._stop_login()
        if self.client is not None:
            await self.client.close()

    def close(self):
        if self.loop.is_running():
            asyncio.run_coroutine_threadsafe(self._close(), self.loop).result(timeout=5)
        self.loop.call_soon_threadsafe(self.loop.stop)
        self.thread.join(timeout=5)
        if not self.loop.is_running():
            self.loop.close()
