"""Minimal in-process request metrics in Prometheus text format.

Deliberately dependency-free: the demo workload does not run a Prometheus server, and CloudWatch
gets its signals from the ALB and ECS. `/metrics` exists for local debugging and a future scraper,
and it is disabled by default (METRICS_ENABLED=false) so it is never exposed through the ALB by
accident.
"""

from __future__ import annotations

import threading
from collections import Counter


class RequestMetrics:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._requests: Counter[tuple[str, str, int]] = Counter()
        self._duration_sum = 0.0
        self._duration_count = 0

    def observe(self, method: str, route: str, status: int, duration_seconds: float) -> None:
        with self._lock:
            self._requests[(method, route, status)] += 1
            self._duration_sum += duration_seconds
            self._duration_count += 1

    def render(self) -> str:
        with self._lock:
            lines = [
                "# HELP http_requests_total HTTP requests by method, route template and status.",
                "# TYPE http_requests_total counter",
            ]
            for (method, route, status), count in sorted(self._requests.items()):
                lines.append(f'http_requests_total{{method="{method}",route="{route}",status="{status}"}} {count}')
            lines += [
                "# HELP http_request_duration_seconds Request latency.",
                "# TYPE http_request_duration_seconds summary",
                f"http_request_duration_seconds_sum {self._duration_sum:.6f}",
                f"http_request_duration_seconds_count {self._duration_count}",
            ]
        return "\n".join(lines) + "\n"
