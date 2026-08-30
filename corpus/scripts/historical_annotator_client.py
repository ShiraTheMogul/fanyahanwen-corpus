#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import atexit
import json
import os
import subprocess
from pathlib import Path
from typing import Any


class HistoricalAnnotatorClient:
    """Thin JSON transport to the existing Rails historical annotator.

    The Python migration planner does not copy person scoring, chronology gates,
    ambiguity rules, or syntax heuristics. One long-lived Ruby process delegates
    those decisions to CbdbAutoAnnotator and returns only the requested matches.
    """

    def __init__(self, repo_root: Path | None = None) -> None:
        self.repo_root = repo_root or Path(__file__).resolve().parents[2]
        self.executable = self.repo_root / "viewer" / "bin" / "historical-annotator"
        self.ruby = os.environ.get("RUBY", "ruby")
        self._process: subprocess.Popen[str] | None = None
        atexit.register(self.close)

    def annotate(
        self,
        text: str,
        *,
        metadata: dict[str, Any],
        wanted: dict[str, list[str] | tuple[str, ...] | set[str]],
    ) -> dict[str, Any]:
        request = {
            "text": text,
            "metadata": metadata,
            "wanted": {key: list(values) for key, values in wanted.items()},
        }
        process = self._ensure_process()
        assert process.stdin is not None
        assert process.stdout is not None
        process.stdin.write(json.dumps(request, ensure_ascii=False, separators=(",", ":")) + "\n")
        process.stdin.flush()
        response_line = process.stdout.readline()
        if not response_line:
            code = process.poll()
            raise RuntimeError(f"historical annotator stopped before replying (exit code {code})")

        response = json.loads(response_line)
        if not isinstance(response, dict):
            raise RuntimeError("historical annotator returned a non-object response")
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
            raise RuntimeError(f"historical annotator executable not found: {self.executable}")

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
