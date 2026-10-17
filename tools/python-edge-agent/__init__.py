"""Privacy-safe reference client for already-gated fleet observations."""

from .edge_agent import EdgeAgent, PolicyError, idempotency_key, prepare_observation

__all__ = ["EdgeAgent", "PolicyError", "idempotency_key", "prepare_observation"]
