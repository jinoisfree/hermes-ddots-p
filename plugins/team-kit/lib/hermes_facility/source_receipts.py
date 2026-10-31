"""Verified original identity shared by source packs and execution guards."""
from contextvars import ContextVar
from contextlib import contextmanager
from hermes_facility.errors import SourceReadError

RECEIPT = ContextVar("verified_source_receipt", default=None)


@contextmanager
def verified_receipt(kind, identifier, value):
    token = RECEIPT.set((kind, identifier, validated(kind, value)))
    try:yield
    finally:RECEIPT.reset(token)


IDENTITY_FIELDS = {
    'notes': ('title', 'created_at', 'folder_id', 'folder_name', 'account_id'),
    'calendar': ('title', 'start', 'end', 'calendar_id', 'recurring', 'id_kind'),
    'notion': ('title', 'created_at', 'database_id'),
}


def validated(kind, value):
    if not isinstance(value, dict) or value.get('owner_scope') not in {'company', 'personal'}:
        raise SourceReadError('transient', 'source_scope_unverified')
    identity = value.get('identity')
    if not isinstance(identity, dict) or any(
        key not in identity or identity[key] is None or identity[key] == ''
        for key in IDENTITY_FIELDS[kind]
    ):
        raise SourceReadError('transient', 'source_identity_incomplete')
    return {'owner_scope': value['owner_scope'], 'identity': {k:identity[k] for k in IDENTITY_FIELDS[kind]}}
