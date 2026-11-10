"""Read a connected app's Cocoa scripting dictionary through the system OSA API.

Only local bundle URLs are accepted. Legacy Cocoa dictionaries require a running
app; discovery never invokes this conversion. The SDK's ASDebugging.h documents
OSACopyScriptingDefinitionFromURL(flags=0).
"""
import ctypes as C
from pathlib import Path

MAX_BYTES = 2 * 1024 * 1024


def from_bundle(path):
    path = Path(path).resolve()
    if not path.is_dir() or path.suffix != '.app': raise ValueError('APP_SDEF_MISSING')
    cf = C.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    osa = C.CDLL('/System/Library/Frameworks/Carbon.framework/Frameworks/OpenScripting.framework/OpenScripting')
    cf.CFURLCreateFromFileSystemRepresentation.argtypes = [C.c_void_p, C.c_char_p, C.c_long, C.c_bool]
    cf.CFURLCreateFromFileSystemRepresentation.restype = C.c_void_p
    cf.CFRelease.argtypes = [C.c_void_p]
    cf.CFDataGetLength.argtypes = [C.c_void_p]; cf.CFDataGetLength.restype = C.c_long
    cf.CFDataGetBytePtr.argtypes = [C.c_void_p]; cf.CFDataGetBytePtr.restype = C.c_void_p
    osa.OSACopyScriptingDefinitionFromURL.argtypes = [C.c_void_p, C.c_int32, C.POINTER(C.c_void_p)]
    osa.OSACopyScriptingDefinitionFromURL.restype = C.c_int32
    raw = bytes(path); url = cf.CFURLCreateFromFileSystemRepresentation(None, raw, len(raw), True)
    if not url: raise ValueError('APP_SDEF_MISSING')
    data = C.c_void_p()
    try:
        status = osa.OSACopyScriptingDefinitionFromURL(url, 0, C.byref(data))
        if status or not data.value: raise ValueError('APP_SDEF_MISSING')
        size = cf.CFDataGetLength(data)
        if not 0 < size <= MAX_BYTES: raise ValueError('APP_SDEF_TOO_LARGE')
        return C.string_at(cf.CFDataGetBytePtr(data), size)
    finally:
        if data.value: cf.CFRelease(data)
        cf.CFRelease(url)
