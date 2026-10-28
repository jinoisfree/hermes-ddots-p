#!/usr/bin/env python3
"""One bounded, detached POP indexing pass. No Hermes agent and no notification writes."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

import mail_app


def run(home, account, seconds=45):
    home = Path(home).resolve()
    if home.name != 'work-assistant' or home.parent.name != 'profiles':
        raise ValueError('MAIL_APP_INDEX_PROFILE_REFUSED')
    root = home.parent.parent
    sys.path.insert(0, str(root / 'hermes-agent'))
    import hermes_yaml
    cfg = hermes_yaml.safe_load((root / 'config.yaml').read_text())
    scopes = cfg['plugins']['entries']['team-kit']['settings']['personal_scopes']
    allowed = {str(a).casefold() for a in scopes.get('company', {}).get('mail_accounts', [])}
    if scopes.get('enabled') is not True or account.casefold() not in allowed:
        raise ValueError('MAIL_APP_INDEX_ACCOUNT_REFUSED')
    settings = hermes_yaml.safe_load((home / 'config.yaml').read_text())['plugins']['entries']['team-delegation']['settings']['gmail']
    if settings.get('company_mail_index') is not True:
        return {'disabled': True}
    return mail_app.fill_index(account, cache_root=home / 'cache/mail-search', seconds=seconds)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home', type=Path, required=True)
    parser.add_argument('--account', required=True)
    parser.add_argument('--seconds', type=float, default=45)
    args = parser.parse_args(argv)
    args.home = args.home.resolve()
    if args.home.name != 'work-assistant' or args.home.parent.name != 'profiles':
        return 1
    try:
        result = run(args.home, args.account, args.seconds)
    except Exception as exc:
        result = {'complete': False, 'error': str(exc) if isinstance(exc, mail_app.MailAppError) else type(exc).__name__}
    # Only counts/IDs/error codes, no body or attachment names in this diagnostic file.
    cache = args.home / 'cache/mail-search'
    cache.mkdir(parents=True, exist_ok=True, mode=0o700)
    stem = hashlib.sha256(args.account.casefold().encode()).hexdigest()[:24]
    fd, temporary = tempfile.mkstemp(prefix='.index-status-', dir=cache)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(result, stream)
        os.replace(temporary, cache / ('index-status-' + stem + '.json'))
    finally:
        Path(temporary).unlink(missing_ok=True)
    return 0 if not result.get('error') else 1


if __name__ == '__main__':
    raise SystemExit(main())
