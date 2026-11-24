"""Read and write only the school's auto-login item in the macOS Keychain."""
import ctypes as c
import os
from functools import lru_cache
import json


BASE_SERVICE = b"cn.schoolis.naisstu.SP_Assignments"
ACCOUNT = b"automatic-login"
SERVICE = (BASE_SERVICE + b"." + os.environ.get("SP_ASSIGNMENTS_ACCOUNT", "").strip().encode()
           if os.environ.get("SP_ASSIGNMENTS_ACCOUNT", "").strip() else BASE_SERVICE)
ITEM = (None, len(SERVICE), SERVICE, len(ACCOUNT), ACCOUNT)
LEGACY_ITEM = (None, len(BASE_SERVICE), BASE_SERVICE, len(ACCOUNT), ACCOUNT)
NOT_FOUND = -25300
DUPLICATE = -25299


class KeychainError(Exception):
    pass


@lru_cache(maxsize=1)
def frameworks():
    try:
        security = c.CDLL("/System/Library/Frameworks/Security.framework/Security")
        foundation = c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        raise KeychainError("无法打开 macOS 钥匙串。") from None
    item_args = [c.c_void_p, c.c_uint32, c.c_char_p, c.c_uint32, c.c_char_p]
    security.SecKeychainFindGenericPassword.argtypes = item_args + [
        c.POINTER(c.c_uint32), c.POINTER(c.c_void_p), c.POINTER(c.c_void_p),
    ]
    security.SecKeychainAddGenericPassword.argtypes = item_args + [
        c.c_uint32, c.c_char_p, c.POINTER(c.c_void_p),
    ]
    security.SecKeychainItemModifyAttributesAndData.argtypes = [c.c_void_p, c.c_void_p, c.c_uint32, c.c_char_p]
    security.SecKeychainItemFreeContent.argtypes = [c.c_void_p, c.c_void_p]
    foundation.CFRelease.argtypes = [c.c_void_p]
    foundation.CFRelease.restype = None
    return security, foundation


def read_credential():
    security, _ = frameworks()
    size, buffer = c.c_uint32(), c.c_void_p()
    status = security.SecKeychainFindGenericPassword(*ITEM, c.byref(size), c.byref(buffer), None)
    if status == NOT_FOUND and ITEM != LEGACY_ITEM:
        status = security.SecKeychainFindGenericPassword(*LEGACY_ITEM, c.byref(size), c.byref(buffer), None)
    if status == NOT_FOUND:
        return None
    if status != 0:
        raise KeychainError("无法读取学校的登录凭据，请解锁 macOS 钥匙串。")
    try:
        credential = json.loads(c.string_at(buffer, size.value))
        if (isinstance(credential, dict) and isinstance(credential.get("name"), str)
                and isinstance(credential.get("digest"), str)
                and isinstance(credential.get("weak"), (bool, int))):
            return credential
        raise ValueError
    except (ValueError, UnicodeDecodeError):
        raise KeychainError("学校的登录凭据格式异常，请重新启用自动登录。") from None
    finally:
        security.SecKeychainItemFreeContent(None, buffer)


def save_credential(credential):
    security, foundation = frameworks()
    data = json.dumps(credential, ensure_ascii=False).encode()
    status = security.SecKeychainAddGenericPassword(*ITEM, len(data), data, None)
    if status == DUPLICATE:
        item = c.c_void_p()
        status = security.SecKeychainFindGenericPassword(*ITEM, None, None, c.byref(item))
        if status == 0:
            try:
                status = security.SecKeychainItemModifyAttributesAndData(item, None, len(data), data)
            finally:
                foundation.CFRelease(item)
    if status != 0:
        raise KeychainError("无法保存学校的登录凭据，请解锁 macOS 钥匙串。")
