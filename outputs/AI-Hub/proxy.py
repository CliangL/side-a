"""The only model transport. No browser/app ever sees provider or proxy credentials."""
import json
import uuid

import httpx

from core import Problem, fail, validate_base_url


class ModelProxy:
    def __init__(self, url, key, cipher, transport=None):
        self.url, self.key, self.cipher = url.rstrip('/'), key, cipher
        self.transport = transport

    def request(self, method, path, body=None, timeout=20):
        try:
            with httpx.Client(timeout=timeout, follow_redirects=False, trust_env=False, transport=self.transport) as client:
                response = client.request(method, self.url + path,
                    headers={'Authorization': 'Bearer ' + self.key}, json=body)
                if response.status_code >= 400:
                    fail('upstream_failed', 502)
                data = response.json()
                if not isinstance(data, dict):
                    fail('upstream_failed', 502)
                return data
        except httpx.TimeoutException:
            fail('upstream_timeout', 504)
        except (httpx.HTTPError, ValueError):
            fail('upstream_failed', 502)

    @staticmethod
    def alias(model):
        return f"hub-{model['id']}-r{model['revision']}"

    def sync(self, model):
        if not self.key or not model['key_enc'] or not model['enabled'] or not model['provider_enabled']:
            fail('model_unconfigured', 503)
        validate_base_url(model['base_url'])
        alias = self.alias(model)
        data = self.request('GET', '/model/info')
        if any(row.get('model_name') == alias for row in data.get('data', [])):
            return alias
        key = self.cipher.decrypt(model['key_enc'].encode()).decode()
        info = {'id': str(uuid.uuid5(uuid.NAMESPACE_URL, alias)),
                'mode': 'responses' if model['api_mode'] == 'responses' else 'chat',
                'supported_endpoints': ['/v1/responses'] if model['api_mode'] == 'responses' else ['/v1/chat/completions'],
                'enforce_supported_endpoints': True}
        # Generic compatible Chat must not inherit official OpenAI model-name
        # heuristics: some gateways expose Responses-only model names via Chat.
        # LiteLLM 1.108's completion path can ignore use_chat_completions_api and
        # still bridge openai/<name> to /responses. custom_openai preserves Chat.
        provider = 'custom_openai/' if model['api_mode'] == 'chat' else 'openai/'
        params = {'model': provider + model['upstream_model'], 'api_key': key, 'api_base': model['base_url'],
                  'max_retries': 0, 'timeout': 100}
        self.request('POST', '/model/new', {'model_name': alias, 'litellm_params': params, 'model_info': info})
        return alias

    def invoke(self, model, system, user, output_tokens=None, json_mode=True):
        # Recheck DNS before dispatch; deployment must also deny private-address egress for the proxy.
        validate_base_url(model['base_url'])
        limit = output_tokens or model['max_output_tokens']
        common = {'model': self.alias(model), 'stream': False}
        if model['api_mode'] == 'responses':
            body = {**common, 'instructions': system, 'input': user, 'max_output_tokens': limit, 'store': False}
            if json_mode:
                body['text'] = {'format': {'type': 'json_object'}}
            result = self.request('POST', '/v1/responses', body, timeout=110)
            if result.get('status') not in (None, 'completed'):
                fail('invalid_model_result', 502)
            content = ''.join(part.get('text', '') for item in result.get('output', [])
                if isinstance(item, dict) and item.get('type') == 'message'
                for part in item.get('content', []) if isinstance(part, dict) and part.get('type') == 'output_text')
            usage = result.get('usage')
        else:
            body = {**common, 'messages': [{'role': 'system', 'content': system}, {'role': 'user', 'content': user}],
                    'max_tokens': limit}
            if json_mode:
                body['response_format'] = {'type': 'json_object'}
            result = self.request('POST', '/v1/chat/completions', body, timeout=110)
            try:
                choice = result['choices'][0]
                if choice.get('finish_reason') not in (None, 'stop'):
                    fail('invalid_model_result', 502)
                content = choice['message']['content']
            except (KeyError, TypeError, IndexError):
                fail('invalid_model_result', 502)
            raw = result.get('usage') or {}
            usage = {'input_tokens': raw.get('prompt_tokens'), 'output_tokens': raw.get('completion_tokens')}
        if not isinstance(content, str) or not content.strip() or len(content) > 32000:
            fail('invalid_model_result', 502)
        return content, usage

    def discover(self, provider):
        if not provider['key_enc']:
            fail('model_unconfigured', 503)
        url = validate_base_url(provider['base_url']) + '/models'
        key = self.cipher.decrypt(provider['key_enc'].encode()).decode()
        try:
            with httpx.Client(timeout=15, follow_redirects=False, trust_env=False, transport=self.transport) as client:
                result = client.get(url, headers={'Authorization': 'Bearer ' + key})
                if result.status_code != 200:
                    raise ValueError()
                # Do not persist or expose arbitrary provider response fields or echoed credentials.
                data = result.json()
                return sorted({row['id'] for row in data.get('data', [])[:1000]
                    if isinstance(row, dict) and isinstance(row.get('id'), str) and len(row['id']) <= 200})
        except (httpx.HTTPError, ValueError, TypeError, AttributeError):
            raise Problem('models_unavailable', '服务商未返回模型列表，可手动填写模型名称', 502)
