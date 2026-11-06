CREATE TABLE IF NOT EXISTS providers (
 id uuid PRIMARY KEY, name text NOT NULL, base_url text NOT NULL,
 key_enc text, enabled boolean NOT NULL DEFAULT true,
 updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS models (
 id uuid PRIMARY KEY, name text NOT NULL, provider_id uuid NOT NULL REFERENCES providers(id),
 upstream_model text NOT NULL, api_mode text NOT NULL CHECK(api_mode IN ('responses','chat')),
 enabled boolean NOT NULL DEFAULT true, revision int NOT NULL DEFAULT 1,
 input_price_per_million numeric(18,8), output_price_per_million numeric(18,8),
 max_input_tokens int NOT NULL DEFAULT 32000, max_output_tokens int NOT NULL DEFAULT 4096,
 status text NOT NULL DEFAULT 'untested', last_test_at timestamptz, last_test_error text,
 proxy_synced_revision int NOT NULL DEFAULT 0,
 updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE models ALTER COLUMN max_input_tokens SET DEFAULT 32000;
ALTER TABLE models ALTER COLUMN max_output_tokens SET DEFAULT 4096;
ALTER TABLE models ADD COLUMN IF NOT EXISTS billing_mode text NOT NULL DEFAULT 'metered'
    CHECK (billing_mode IN ('metered','subscription'));
CREATE TABLE IF NOT EXISTS apps (
 id uuid PRIMARY KEY, name text NOT NULL, key_hash text NOT NULL UNIQUE,
 key_prefix text NOT NULL, enabled boolean NOT NULL DEFAULT true,
 model_id uuid REFERENCES models(id), monthly_budget_usd numeric(18,6) NOT NULL DEFAULT 5,
 min_interval_seconds int NOT NULL DEFAULT 300,
 capabilities jsonb NOT NULL DEFAULT '["music.recommend.v1"]',
 created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS workers (
 id uuid PRIMARY KEY, name text NOT NULL, key_hash text NOT NULL UNIQUE,
 key_prefix text NOT NULL, enabled boolean NOT NULL DEFAULT true,
 app_ids jsonb NOT NULL DEFAULT '[]', last_seen_at timestamptz
);
ALTER TABLE workers ADD COLUMN IF NOT EXISTS ready boolean NOT NULL DEFAULT false;
ALTER TABLE workers ADD COLUMN IF NOT EXISTS model_configured boolean NOT NULL DEFAULT false;
ALTER TABLE workers ADD COLUMN IF NOT EXISTS agent_version text;
ALTER TABLE workers ADD COLUMN IF NOT EXISTS capabilities jsonb NOT NULL DEFAULT '[]';
CREATE TABLE IF NOT EXISTS tasks (
 id uuid PRIMARY KEY, app_id uuid NOT NULL REFERENCES apps(id), subject text NOT NULL,
 capability text NOT NULL, executor text NOT NULL CHECK(executor IN ('model','hermes')),
 model_id uuid NOT NULL REFERENCES models(id), model_revision int NOT NULL,
 request_hash text NOT NULL, idempotency_key text, input jsonb NOT NULL,
 status text NOT NULL CHECK(status IN ('queued','leased','running','succeeded','failed','cancelled')),
 result jsonb, error_code text, created_at timestamptz NOT NULL DEFAULT now(),
 started_at timestamptz, completed_at timestamptz, cancel_requested boolean NOT NULL DEFAULT false,
 lease_owner text, lease_token text, lease_until timestamptz, attempts int NOT NULL DEFAULT 0,
 reserved_usd numeric(18,8) NOT NULL DEFAULT 0, charged_usd numeric(18,8) NOT NULL DEFAULT 0,
 input_rate numeric(18,8) NOT NULL, output_rate numeric(18,8) NOT NULL,
 max_input_tokens int NOT NULL, max_output_tokens int NOT NULL,
 input_tokens int, output_tokens int, usage_estimated boolean NOT NULL DEFAULT false,
 UNIQUE(app_id,subject,idempotency_key)
);
CREATE INDEX IF NOT EXISTS tasks_claim ON tasks(executor,status,created_at);
CREATE INDEX IF NOT EXISTS tasks_subject ON tasks(app_id,subject,capability,created_at DESC);
CREATE INDEX IF NOT EXISTS tasks_budget ON tasks(app_id,created_at);
CREATE INDEX IF NOT EXISTS tasks_cache ON tasks(app_id,subject,request_hash,completed_at DESC);
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS relay_status text;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS relay_response jsonb;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS relay_usage jsonb;
ALTER TABLE tasks ADD COLUMN IF NOT EXISTS billing_mode text NOT NULL DEFAULT 'metered'
    CHECK (billing_mode IN ('metered','subscription'));
CREATE TABLE IF NOT EXISTS auth_attempts (
 identity text PRIMARY KEY, failures int NOT NULL DEFAULT 0, first_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS model_tests (
 id uuid PRIMARY KEY, model_id uuid NOT NULL REFERENCES models(id),
 success boolean NOT NULL, error_code text, input_tokens int, output_tokens int,
 estimated_usd numeric(18,8), created_at timestamptz NOT NULL DEFAULT now()
);
