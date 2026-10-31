"""Environment-driven configuration with pydantic validation.

Every field has a safe default so the service boots with zero configuration;
missing credentials for optional features surface later as ConfigError at the
point of use instead of crashing startup (demo-friendly, same philosophy as SyncFlow).
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

VALID_PROVIDERS = ("openai", "anthropic", "fake")


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # --- Server ---
    port: int = Field(default=8090, gt=0, le=65535)
    database_path: str = "./data/askdocs.db"
    log_level: str = "INFO"
    log_pretty: bool = False

    # --- LLM providers ---
    llm_provider: str = "anthropic"
    openai_api_key: str = ""
    anthropic_api_key: str = ""
    openai_chat_model: str = "gpt-4o-mini"
    anthropic_chat_model: str = "claude-sonnet-4-20250514"
    llm_max_tokens: int = Field(default=1024, gt=0)
    llm_timeout_seconds: float = Field(default=60.0, gt=0)

    # --- Embeddings (always via OpenAI, see README for the rationale) ---
    embedding_model: str = "text-embedding-3-small"
    embedding_dimensions: int = Field(default=256, gt=0, le=3072)

    # --- Retrieval / guardrails ---
    retrieval_top_k: int = Field(default=4, ge=1, le=32)
    retrieval_min_score: float = Field(default=0.30, ge=0.0, le=1.0)

    # --- Per-user rate limiting (token bucket) ---
    rate_limit_capacity: float = Field(default=20.0, gt=0)
    rate_limit_refill_per_sec: float = Field(default=0.5, gt=0)

    # --- Human-handoff workflow ---
    airtable_api_key: str = ""
    airtable_base_id: str = ""
    airtable_tickets_table: str = "Support Tickets"
    slack_webhook_url: str = ""
    public_base_url: str = "http://localhost:8090"
    handoff_neg_feedback_threshold: int = Field(default=2, ge=1)

    # --- Job queue ---
    job_poll_interval_ms: int = Field(default=1000, ge=50)
    job_max_attempts: int = Field(default=5, ge=1)
    backoff_base_ms: int = Field(default=1000, ge=1)
    backoff_max_ms: int = Field(default=300_000, ge=1)

    @field_validator("log_level")
    @classmethod
    def _upper_log_level(cls, v: str) -> str:
        upper = v.upper()
        if upper not in ("DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"):
            raise ValueError(f"invalid log level: {v}")
        return upper

    @field_validator("llm_provider")
    @classmethod
    def _valid_provider(cls, v: str) -> str:
        lower = v.lower()
        if lower not in VALID_PROVIDERS:
            raise ValueError(f"LLM_PROVIDER must be one of {VALID_PROVIDERS}")
        return lower


@lru_cache
def get_settings() -> Settings:
    return Settings()
