#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import atexit
import json
import os
import subprocess
from pathlib import Path
from typing import Any


class CalendarEngineClient:
    """Thin JSON transport to the Rails CalendarEngine.

    This module intentionally contains no calendar arithmetic, epoch constants,
    Chinese-number parsing, or historical nomenclature. One long-lived Ruby
    process is shared and exact requests are cached, so corpus audits do not pay
    the Rails boot cost for every category label.
    """

    def __init__(self, repo_root: Path | None = None) -> None:
        self.repo_root = repo_root or Path(__file__).resolve().parents[2]
        self.executable = self.repo_root / "viewer" / "bin" / "calendar-engine"
        self.ruby = os.environ.get("RUBY", "ruby")
        self._process: subprocess.Popen[str] | None = None
        self._cache: dict[str, dict[str, Any]] = {}
        atexit.register(self.close)

    def resolve(
        self,
        value: str,
        *,
        context: dict[str, Any] | None = None,
        system: str | None = None,
        authority: bool = True,
    ) -> dict[str, Any]:
        request: dict[str, Any] = {"operation": "resolve", "value": value, "authority": authority}
        if context:
            request["context"] = context
        if system:
            request["system"] = system
        return self.call(request)

    def resolve_prefix(
        self,
        value: str,
        *,
        context: dict[str, Any] | None = None,
        authority: bool = False,
    ) -> dict[str, Any]:
        request: dict[str, Any] = {
            "operation": "resolve_prefix",
            "value": value,
            "authority": authority,
        }
        if context:
            request["context"] = context
        return self.call(request)

    def period_bounds(self, value: str | list[str] | tuple[str, ...]) -> dict[str, Any]:
        """Return established Gregorian historical bounds for period/path labels.

        The client transports labels only. Period authority data and range
        intersection remain in Rails CalendarEngine.
        """
        payload: str | list[str]
        payload = list(value) if isinstance(value, tuple) else value
        return self.call({"operation": "period_bounds", "value": payload})

    def systems(self) -> dict[str, Any]:
        return self.call({"operation": "systems"})

    def call(self, request: dict[str, Any]) -> dict[str, Any]:
        cache_key = json.dumps(request, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        process = self._ensure_process()
        assert process.stdin is not None
        assert process.stdout is not None
        process.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
        process.stdin.flush()
        response_line = process.stdout.readline()
        if not response_line:
            code = process.poll()
            raise RuntimeError(f"calendar engine stopped before replying (exit code {code})")

        response = json.loads(response_line)
        if not isinstance(response, dict):
            raise RuntimeError("calendar engine returned a non-object response")
        self._cache[cache_key] = response
        return response

    def close(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return
        if process.stdin is not None and not process.stdin.closed:
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def _ensure_process(self) -> subprocess.Popen[str]:
        if self._process is not None and self._process.poll() is None:
            return self._process
        if not self.executable.is_file():
            raise RuntimeError(f"calendar engine executable not found: {self.executable}")

        self._process = subprocess.Popen(
            [self.ruby, str(self.executable), "--stream"],
            cwd=self.repo_root / "viewer",
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="strict",
        )
        return self._process
