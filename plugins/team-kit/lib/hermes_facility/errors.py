"""Shared fail-closed errors for source readers."""
class SourceReadError(ValueError):
    def __init__(self, status, reason):
        self.status, self.reason = status, reason
        # Retain the legacy fail-closed prefix for existing authorization callers.
        super().__init__('PERSONAL_SCOPE_UNVERIFIED: ' + reason)
