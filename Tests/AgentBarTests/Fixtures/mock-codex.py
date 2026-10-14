#!/usr/bin/python3
"""Deterministic subprocess for RPC lifetime and backpressure regression tests."""
import json
import os
import signal
import sys
import time

if "--version" in sys.argv:
    if os.path.basename(sys.argv[0]) == "version-hang":
        time.sleep(10)
    print("codex-cli 0.142.3")
    sys.exit(0)

mode = sys.argv[1] if len(sys.argv) > 1 else "normal"
request_counts = {}
signed_out = False
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)


def respond(request, result):
    print(json.dumps({"id": request["id"], "result": result}), flush=True)


try:
    for line in sys.stdin:
        request = json.loads(line)
        method = request["method"]
        if "id" not in request:
            continue
        request_counts[method] = request_counts.get(method, 0) + 1
        if method == "initialize":
            if mode == "slow-start":
                time.sleep(0.2)
            respond(request, {})
        elif method == "ignore":
            continue
        elif method == "oversized":
            sys.stdout.write("x" * (1024 * 1024))
            sys.stdout.flush()
        elif method == "flood":
            for index in range(5000):
                print(json.dumps({"method": "unused/notification", "params": {"index": index}}))
            respond(request, {"pid": os.getpid()})
        elif method == "linger":
            respond(request, {"pid": os.getpid()})
            while True:
                time.sleep(0.05)
        elif method == "account/read":
            if signed_out:
                respond(request, {"account": None, "requiresOpenaiAuth": True})
            elif mode.startswith("workspace-timeout") and (mode != "workspace-timeout-recovery" or request_counts[method] == 1):
                print(json.dumps({"id": request["id"], "error": {"code": -32603, "message": "workspace routing discovery timed out"}}), flush=True)
            elif mode == "account-error":
                print(json.dumps({"id": request["id"], "error": {"code": -32603, "message": "Unauthorized"}}), flush=True)
            elif mode == "not-signed-in":
                respond(request, {"account": None, "requiresOpenaiAuth": True})
            else:
                respond(request, {"account": {"type": "chatgpt", "planType": "plus", "email": "test@example.com"}})
        elif method == "account/rateLimits/read":
            if mode == "workspace-timeout-quota-error":
                print(json.dumps({"id": request["id"], "error": {"code": -32603, "message": "Quota endpoint unavailable"}}), flush=True)
            else:
                respond(request, {"rateLimits": {"limitId": "codex", "planType": "pro" if mode == "workspace-timeout-pro" else "plus", "primary": {"windowDurationMins": 300, "usedPercent": 15}, "secondary": {"windowDurationMins": 10080, "usedPercent": 12}}})
        elif method == "account/usage/read":
            if mode == "slow-usage":
                time.sleep(0.2)
            respond(request, {"summary": {"lifetimeTokens": 100}, "dailyUsageBuckets": []})
        elif method == "request-counts":
            respond(request, request_counts)
        elif method == "notify-rate-limits":
            print(json.dumps({"method": "account/rateLimits/updated", "params": {}}), flush=True)
            respond(request, {})
        elif method == "notify-logout":
            signed_out = True
            print(json.dumps({"method": "account/updated", "params": {"authMode": None}}), flush=True)
            respond(request, {})
        else:
            size = 32 * 1024 if method == "large" else 256
            respond(request, {"pid": os.getpid(), "payload": "x" * size})
except (BrokenPipeError, OSError):
    os._exit(0)
