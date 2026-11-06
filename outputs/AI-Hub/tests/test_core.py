import json
import socket
from decimal import Decimal

import httpx
import pytest
from cryptography.fernet import Fernet

from core import Problem, estimate_reservation, validate_base_url, validate_input, validate_result
from proxy import ModelProxy


INPUT = {'profile': {'completions': 8}, 'candidates': [{'id': 'a', 'title': '山间清晨', 'artist': '甲'}], 'limit': 1}


@pytest.mark.parametrize('url', [
    'http://api.example.com/v1', 'https://127.0.0.1/v1', 'https://[::1]/v1',
    'https://169.254.169.254/latest', 'https://10.1.2.3/v1', 'https://192.168.1.1',
    'https://172.16.0.1', 'https://localhost/v1', 'https://a.internal/v1',
    'https://user:password@example.com/v1', 'https://example.com:8080/v1',
    'https://example.com/v1?api_key=secret', 'https://example.com/v1#x',
    'https://127%2e0%2e0%2e1/v1', 'file:///etc/passwd',
])
def test_provider_urls_reject_private_and_credential_targets(url):
    with pytest.raises(Problem):
        validate_base_url(url)


def test_dns_resolving_to_internal_is_rejected(monkeypatch):
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *_a, **_k: [(2, 1, 6, '', ('10.0.0.4', 443))])
    with pytest.raises(Problem):
        validate_base_url('https://public-looking.example/v1')


def test_public_provider_url_allowed(monkeypatch):
    monkeypatch.setattr(socket, 'getaddrinfo', lambda *_a, **_k: [(2, 1, 6, '', ('1.1.1.1', 443))])
    assert validate_base_url('https://api.example.com/v1/') == 'https://api.example.com/v1'


@pytest.mark.parametrize('value', [
    {'profile_summary': '偏好轻音乐', 'ranked': [{'id': 'invented', 'reason': '喜欢'}]},
    {'profile_summary': '偏好轻音乐', 'ranked': [{'id': 'a', 'reason': '喜欢'}, {'id': 'a', 'reason': '重复'}]},
    {'profile_summary': '偏好轻音乐', 'ranked': []},
    {'profile_summary': '偏好轻音乐', 'ranked': [{'id': 'a', 'reason': '喜欢', 'url': 'https://evil.example'}]},
    {'profile_summary': '偏好轻音乐', 'ranked': [{'id': 'a', 'reason': '喜欢'}], 'command': 'execute'},
])
def test_model_cannot_invent_tracks_or_expand_schema(value):
    with pytest.raises(Problem, match='候选歌曲'):
        validate_result('music.recommend.v1', value, INPUT)


def test_valid_recommendation_preserves_real_ids():
    value = {'profile_summary': '偏好有较高完播率的歌曲', 'ranked': [{'id': 'a', 'reason': '近期完整播放较多'}]}
    assert validate_result('music.recommend.v1', value, INPUT) == value


def test_duplicate_candidates_and_credentials_rejected():
    with pytest.raises(Problem):
        validate_input('music.recommend.v1', {**INPUT, 'candidates': INPUT['candidates'] * 2})
    with pytest.raises(Problem):
        validate_input('music.recommend.v1', {**INPUT, 'profile': {'api_key': 'secret'}})


def test_reservation_requires_known_prices_and_bounds_input():
    model = {'input_price_per_million': None, 'output_price_per_million': 2, 'max_input_tokens': 2000, 'max_output_tokens': 200}
    with pytest.raises(Problem) as error:
        estimate_reservation(model, 'system', 'user')
    assert error.value.code == 'pricing_required'
    model['input_price_per_million'] = 1
    count, amount = estimate_reservation(model, '系统', '用户')
    assert count == 1036 and amount == Decimal('0.00143600')
    with pytest.raises(Problem):
        estimate_reservation(model, '系统', '长' * 1000)


def test_subscription_records_usage_without_claiming_a_token_fee():
    model = {'billing_mode': 'subscription', 'input_price_per_million': None, 'output_price_per_million': None,
             'max_input_tokens': 4000, 'max_output_tokens': 200}
    count, reserve = estimate_reservation(model, 'system', 'user')
    assert count > 0 and reserve == 0
    with pytest.raises(Problem):
        estimate_reservation(model, 'system', 'x' * 5000)


@pytest.mark.parametrize('mode,endpoint', [('responses', '/v1/responses'), ('chat', '/v1/chat/completions')])
def test_proxy_calls_selected_protocol_without_exposing_key(monkeypatch, mode, endpoint):
    monkeypatch.setattr('proxy.validate_base_url', lambda value: value)
    observed = []
    def handler(request):
        payload = json.loads(request.content)
        observed.append((request.url.path, payload))
        assert request.headers['authorization'] == 'Bearer private-proxy-key'
        assert 'api_key' not in payload
        if mode == 'responses':
            return httpx.Response(200, json={'status': 'completed', 'output': [{'type': 'message', 'content': [{'type': 'output_text', 'text': '{"ok":true}'}]}], 'usage': {'input_tokens': 10, 'output_tokens': 5}})
        return httpx.Response(200, json={'choices': [{'finish_reason': 'stop', 'message': {'content': '{"ok":true}'}}], 'usage': {'prompt_tokens': 10, 'completion_tokens': 5}})
    route = ModelProxy('http://localhost:4000', 'private-proxy-key', Fernet(Fernet.generate_key()), httpx.MockTransport(handler))
    model = {'id': '1', 'revision': 2, 'base_url': 'https://api.example.com/v1', 'api_mode': mode, 'max_output_tokens': 100}
    result, usage = route.invoke(model, 'JSON only', 'test')
    assert result == '{"ok":true}' and usage['input_tokens'] == 10
    assert observed[0][0] == endpoint
    if mode == 'responses':
        assert observed[0][1]['store'] is False


def test_proxy_errors_do_not_echo_upstream_credentials(monkeypatch):
    monkeypatch.setattr('proxy.validate_base_url', lambda value: value)
    route = ModelProxy('http://localhost:4000', 'key', Fernet(Fernet.generate_key()),
                       httpx.MockTransport(lambda _: httpx.Response(401, json={'error': 'bad api_key SECRET'})))
    with pytest.raises(Problem) as error:
        route.request('POST', '/v1/responses', {})
    assert 'SECRET' not in str(error.value)


def test_proxy_refuses_upstream_redirects():
    route = ModelProxy('http://localhost:4000', 'key', Fernet(Fernet.generate_key()),
                       httpx.MockTransport(lambda _: httpx.Response(307, headers={'Location': 'http://169.254.169.254/'})))
    with pytest.raises(Problem):
        route.request('GET', '/model/info')


@pytest.mark.parametrize('mode', ['chat', 'responses'])
def test_proxy_registration_preserves_selected_compatible_protocol(monkeypatch, mode):
    monkeypatch.setattr('proxy.validate_base_url', lambda value: value)
    cipher = Fernet(Fernet.generate_key())
    created = []
    def handler(request):
        if request.url.path == '/model/info':
            return httpx.Response(200, json={'data': []})
        assert request.url.path == '/model/new'
        created.append(json.loads(request.content))
        return httpx.Response(200, json={'ok': True})
    route = ModelProxy('http://localhost:4000', 'private-proxy-key', cipher, httpx.MockTransport(handler))
    model = {'id': '00000000-0000-4000-8000-000000000001', 'revision': 3,
             'base_url': 'https://api.example.com/v1', 'upstream_model': 'gpt-6.1-terra',
             'api_mode': mode, 'enabled': True, 'provider_enabled': True,
             'key_enc': cipher.encrypt(b'server-only-test-key').decode()}
    route.sync(model)
    if mode == 'chat':
        assert created[0]['litellm_params']['model'] == 'custom_openai/gpt-6.1-terra'
        assert 'use_chat_completions_api' not in created[0]['litellm_params']
        assert created[0]['model_info']['supported_endpoints'] == ['/v1/chat/completions']
    else:
        assert created[0]['litellm_params']['model'] == 'openai/gpt-6.1-terra'
        assert 'use_chat_completions_api' not in created[0]['litellm_params']
        assert created[0]['model_info']['supported_endpoints'] == ['/v1/responses']


def test_discovery_flags_are_optional_strict_and_preserved():
    from core import prompt_for
    legacy = validate_input('music.recommend.v1', INPUT)
    assert 'familiar' not in legacy['candidates'][0]
    candidate = {**INPUT['candidates'][0], 'familiar': True, 'recent': False, 'shown': True}
    clean = validate_input('music.recommend.v1', {**INPUT, 'candidates': [candidate]})
    assert clean['candidates'][0] == candidate
    system, user = prompt_for('music.recommend.v1', clean)
    assert '四分之三' in system and 'familiar' in system and 'shown' in system
    for invalid in ('yes', 1, None):
        with pytest.raises(Problem):
            validate_input('music.recommend.v1', {**INPUT, 'candidates': [{**candidate, 'familiar': invalid}]})
