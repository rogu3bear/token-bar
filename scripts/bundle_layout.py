#!/usr/bin/env python3
"""Shipping bundle layout for verification and preview scripts.

build.sh still writes these names into the app. DuplicateScan.installedPath is
/Applications plus the bundle name. This module is the shared reader so
preview and release comparison cannot drift from each other.
"""
from pathlib import Path
import sys

BUNDLE_NAME = "Token Bar.app"
EXECUTABLE_NAME = "TokenBar"


def repo_root():
    return Path(__file__).resolve().parent.parent


def built_app(root=None):
    return (root or repo_root()) / "build" / BUNDLE_NAME


def built_executable(root=None):
    return built_app(root) / "Contents" / "MacOS" / EXECUTABLE_NAME


def payload_app(root):
    return root / "Payload" / BUNDLE_NAME


def payload_executable(root):
    return payload_app(root) / "Contents" / "MacOS" / EXECUTABLE_NAME


if __name__ == "__main__":
    kind = sys.argv[1] if len(sys.argv) > 1 else ""
    mapping = {
        "bundle-name": BUNDLE_NAME,
        "executable-name": EXECUTABLE_NAME,
        "app": str(built_app()),
        "executable": str(built_executable()),
    }
    if kind not in mapping:
        sys.exit("usage: bundle_layout.py bundle-name|executable-name|app|executable")
    print(mapping[kind])
