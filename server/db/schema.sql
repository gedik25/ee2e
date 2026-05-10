-- EE2E — Initial schema
-- Faz 1: yapı kurulur, tablolar boş kalır.
-- Faz 2: key_bundles ve one_time_prekeys doldurulur.
-- HİÇBİR private key veya plaintext message bu DB'ye yazılmaz.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- Kullanıcı (Faz 3'te multi-device için her cihaz ayrı row)
CREATE TABLE IF NOT EXISTS users (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    handle       TEXT UNIQUE NOT NULL,
    device_label TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Public key bundle (Faz 2)
CREATE TABLE IF NOT EXISTS key_bundles (
    user_id        UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
    identity_key   BYTEA NOT NULL,
    signed_prekey  BYTEA NOT NULL,
    spk_signature  BYTEA NOT NULL,
    spk_id         INT  NOT NULL,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- One-time prekey havuzu (Faz 2). Kullanıldığında SİLİNİR.
CREATE TABLE IF NOT EXISTS one_time_prekeys (
    id         BIGSERIAL PRIMARY KEY,
    user_id    UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    opk_id     INT  NOT NULL,
    public_key BYTEA NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (user_id, opk_id)
);

CREATE INDEX IF NOT EXISTS idx_opk_user ON one_time_prekeys (user_id);

-- Mesaj tablosu YOK. Mesajlar disk'e ASLA yazılmaz.
-- Faz 1'de in-memory queue, Faz 3'te Redis (TTL).
