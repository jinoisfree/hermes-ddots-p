"""Shared learning, reports and operating services, independent of plugin directories."""
from hermes_facility.loading import fresh


def load(name, namespace):
    if not name.isidentifier():
        raise ValueError('invalid service name')
    return fresh(__name__ + '.' + name, namespace)
