-- Create a dedicated database for LiteLLM key/budget management.
-- Runs only on first cluster init (empty data dir). LiteLLM creates its own
-- tables there on start when DATABASE_URL points at it.
SELECT 'CREATE DATABASE litellm'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'litellm')\gexec
