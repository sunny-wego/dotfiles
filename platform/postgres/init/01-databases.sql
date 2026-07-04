-- Extra logical databases on the single Postgres instance.
-- `platform` is created by POSTGRES_DB; these two are the sidecar stores.
CREATE DATABASE litellm;   -- LiteLLM virtual keys, budgets, spend ledger
CREATE DATABASE authelia;  -- Authelia sessions / user store
