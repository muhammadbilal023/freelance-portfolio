"""Shared pydantic request/response models."""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field


class ChatRequest(BaseModel):
    session_id: str = ""
    question: str = Field(min_length=1, max_length=2000)


class FeedbackRequest(BaseModel):
    message_id: int = Field(gt=0)
    rating: Literal["helpful", "not_helpful"]
