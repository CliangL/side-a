"""Offline provider checks. No upstream login, account or playable URL is required."""
import asyncio
import time
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace as N
from unittest import TestCase, main
from unittest.mock import AsyncMock, patch

from niquests import Response
from niquests.cookies import RequestsCookieJar
from qqmusic_api import Client, Credential, CredentialRefreshError
from qqmusic_api.core.response import snapshot_payload
from qqmusic_api.core.transport import NiquestsTransport
from qqmusic_api.models.login import QRCodeLoginEvents
from qq_provider import QQProvider, ProviderError, _QQTransport, _media_url


class QQProviderTests(TestCase):
    def setUp(self):
        self.tmp = TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.provider = QQProvider(self.root)
        self.upstream = self.stub(self.provider)

    @staticmethod
    def stub(provider):
        login = N(get_qrcode=AsyncMock(return_value=N(data=b"\x89PNG\r\n\x1a\nqr",mimetype="image/png")),
                  check_qrcode=AsyncMock(return_value=N(event=QRCodeLoginEvents.SCAN)), check_expired=AsyncMock(return_value=False),
                  refresh_credential=AsyncMock())
        file = N(media_mid="StudioMedia",size_flac=12000000,size_320mp3=1000000)
        detail = N(track=N(type=0,file=file, interval=120))
        song = N(get_detail=AsyncMock(return_value=detail),get_song_urls=AsyncMock(),
                 get_cdn_dispatch=AsyncMock(return_value=N(sip=["http://isure.stream.qqmusic.qq.com/"])))
        upstream = N(login=login,song=song,close=AsyncMock())
        provider.client=upstream
        return upstream

    def tearDown(self):
        self.provider.close()
        self.tmp.cleanup()

    def wait_state(self, attempt, expected):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            result = self.provider.login_status(attempt)
            if result["status"] == expected:
                return result
            time.sleep(0.02)
        self.fail(f"Expected {expected}, got {result}")

    def approve(self):
        cred=Credential(musicid=123456, musickey="test-private-fakekey",refresh_key="test-fake-refresh")
        self.upstream.login.check_qrcode.return_value=N(event=QRCodeLoginEvents.DONE,credential=cred)
        attempt = self.provider.start_login()
        approved=self.wait_state(attempt["id"], "connected")
        self.assertEqual(approved["status"],"connected")
        self.assertNotIn("test-private",str(approved))
        return attempt["id"]

    def test_qr_approval_is_kept_off_clients_survives_restart_and_can_be_revoked(self):
        self.assertFalse(self.provider.status()["connected"])
        old = self.provider.start_login()["id"]
        current = self.approve()
        self.assertEqual(self.provider.login_status(old)["status"],"expired")
        encrypted = self.provider.auth_file.read_bytes()
        self.assertNotIn(b"test-private", encrypted)
        self.assertEqual(self.provider.auth_file.stat().st_mode & 0o777,0o600)
        other = QQProvider(self.root)
        try:
            self.stub(other)
            self.assertTrue(other.status()["connected"])
        finally:
            other.close()
        self.provider.logout()
        self.assertFalse(self.provider.auth_file.exists())
        self.assertFalse(self.provider.status()["connected"])
        self.assertEqual(self.provider.login_status(current)["status"],"expired")

    def test_confirmed_web_login_with_empty_etk_uses_real_sdk(self):
        # Replay only synthetic protocol replies. The pinned SDK runs its actual
        # ptqrlogin, check_sig, OAuth and successful QQLogin decoding paths.
        endpoints = []
        client = Client(device_path=str(self.root / "sdk-device.json"),
                        transport=_QQTransport(max_concurrency=3))
        self.provider.client = client
        def reply(url, body, cookie_map=None, headers=None):
            r = Response()
            r.url, r.status_code, r._content, r.encoding = url, 200, body, "utf-8"
            r.headers.update(headers or {})
            r.cookies = RequestsCookieJar()
            for key, value in (cookie_map or {}).items():
                r.cookies.set(key, value)
            return r

        async def synthetic(transport, requests, **kwargs):
            req, = requests
            end = req.url.rsplit("/", 1)[-1]
            endpoints.append(end)
            if end == "ptqrshow":
                return [reply(req.url, b"\x89PNG\r\n\x1a\nexample", {"qrsig": "fakeqr"})]
            if end == "ptqrlogin":
                body = b"ptuiCB('0','0','https://example.invalid/?uin=123&service=ok&ptsigx=ticket&s_url=q','0','','')"
                raw = reply(req.url, body, {"ETK": ""})
                with self.assertRaises(KeyError):  # precisely reproduces v0.8.2 issue #305
                    snapshot_payload(raw)
                return [raw]
            if end == "check_sig":
                return [reply(req.url, b"", {"ETK": "", "p_skey": "synthetic-skey"})]
            if end == "authorize":
                self.assertEqual(req.kwargs["cookies"]["p_skey"], "synthetic-skey")
                return [reply(req.url, b"", headers={"Location": "https://example.invalid/?code=fakecode&state=q"})]
            self.fail("Unexpected SDK request")
        exchange = AsyncMock(return_value={"musicid": 123456, "musickey": "fake-music-key"})
        with patch.object(NiquestsTransport, "request_many", synthetic), patch.object(client.login, "_build_cgi", exchange):
            code = self.provider.start_login()
            # Simulate a browser that closes after showing the code.
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline and not self.provider.auth_file.exists():
                time.sleep(.02)
            self.assertTrue(self.provider.auth_file.exists())
            self.assertEqual(self.provider.login_status(code["id"])["status"], "connected")
            self.assertEqual(exchange.await_args.kwargs["param"]["code"], "fakecode")
        self.assertEqual(endpoints, ["ptqrshow", "ptqrlogin", "check_sig", "authorize"])

    def test_mobile_login_confirms_without_browser_polling(self):
        owner = Credential(musicid=123456, musickey="fake-mobile-key")
        async def events(qr, deadline):
            yield N(event=QRCodeLoginEvents.SCAN)
            await asyncio.sleep(.05)
            yield N(event=QRCodeLoginEvents.CONF)
            await asyncio.sleep(.05)
            yield N(event=QRCodeLoginEvents.DONE, credential=owner)
        self.upstream.login.checking_mobile_qrcode = events
        qr = self.provider.start_login("mobile")
        self.assertIn("QQ 音乐", qr["message"])
        timeout = time.monotonic() + 3
        while time.monotonic() < timeout and not self.provider.auth_file.exists():
            time.sleep(.02)
        self.assertTrue(self.provider.auth_file.exists())
        self.assertEqual(self.provider.login_status(qr["id"])["status"], "connected")
        self.upstream.login.check_qrcode.assert_not_called()

    def test_denial_and_device_limits_never_resolve_to_preview_audio(self):
        for code in (104003,104013):
            self.upstream.song.get_song_urls.return_value=N(data=[N(result=code)])
            with self.assertRaises(ProviderError):
                self.provider.url("recording",999)
            self.upstream.song.get_cdn_dispatch.assert_not_called()
        self.upstream.song.get_song_urls.return_value=N(data=[N(result=0,mid="recording",
            filename="C400StudioMedia.m4a",purl="preview.m4a")])
        with self.assertRaises(ProviderError):
            self.provider.url("recording",999)
        self.upstream.song.get_cdn_dispatch.assert_not_called()

    def test_authorized_recording_format_and_safe_delivery_url(self):
        self.approve()
        self.upstream.song.get_song_urls.return_value=N(data=[N(result=0,mid="recording",
            filename="F000StudioMedia.flac",purl="F000StudioMedia.flac")])
        stream=self.provider.url("recording",999)
        self.assertEqual(stream["url"],"https://isure.stream.qqmusic.qq.com/F000StudioMedia.flac")
        self.assertEqual(stream["size"],12000000)
        self.assertEqual(stream["br"],800)
        self.assertEqual(self.upstream.song.get_song_urls.await_args.kwargs["credential"].musicid,123456)
        self.assertIsNone(_media_url("https://music.example.net/","/song"))
        self.assertIsNone(_media_url("https://qq.com.example.net/","/song"))

    def test_expired_qr_cannot_replace_existing_account(self):
        self.approve()
        self.upstream.login.check_qrcode.return_value=N(event=QRCodeLoginEvents.TIMEOUT,credential=None)
        next_id=self.provider.start_login()["id"]
        self.wait_state(next_id, "expired")
        self.assertTrue(self.provider.status()["connected"])

    def test_confirmed_expiry_clears_login_but_transient_failure_preserves_it(self):
        self.approve()
        self.upstream.login.check_expired.return_value=True
        for code, should_keep in ((-1,True),(104401,False)):
            self.provider.next_account_check=0
            self.upstream.login.refresh_credential.side_effect=CredentialRefreshError(code=code)
            with self.assertRaises(ProviderError):
                self.provider.url("recording",999)
            self.assertEqual(self.provider.auth_file.exists(),should_keep)


if __name__ == "__main__":
    main()
