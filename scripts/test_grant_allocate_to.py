#!/usr/bin/env python3
"""scripts/grant-allocate-to.py 的 --apply 路徑測試：只連本機假伺服器（127.0.0.1 隨機 port），不連任何真的 IAM。

執行：python3 scripts/test_grant_allocate_to.py
"""
import contextlib
import importlib.util
import io
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("grant_allocate_to", os.path.join(HERE, "grant-allocate-to.py"))
script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(script)

FOR_PERM = script.PREFIX + "AllocateForMain"
TO_PERM = script.PREFIX + "AllocateToMain"


def make_server(add_permissions_reply):
    """add_permissions_reply：(status, body) 回給 POST /roles/{id}/add-permissions；成功（200）時才讓 AllocateTo 持有者變成 u1。"""
    state = {"posts": [], "granted": False}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _send(self, status, body):
            raw = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

        def do_GET(self):
            url = urlparse(self.path)
            q = parse_qs(url.query)
            if url.path == "/roles":
                self._send(200, [{"roleId": "r1", "name": "分配人員", "permissions": [FOR_PERM]}])
            elif url.path == "/employee-access/role-holders":
                self._send(200, ["u1"])
            elif url.path == "/employee-access/permission-holders":
                perm = q["permission"][0]
                # AllocateTo 的持有者：角色寫入成功、或「別人已先更新角色」（回應 422 已存在）之後都是 u1
                self._send(200, ["u1"] if perm == FOR_PERM or state["granted"] else [])
            else:
                self._send(404, {})

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(length) or b"{}")
            state["posts"].append((self.path, body))
            status, reply = add_permissions_reply
            if self.path == "/roles/r1/add-permissions":
                if status == 200 or reply.get("error") in ("permissionsUnchanged", "permissionAlreadyExists"):
                    state["granted"] = True
                self._send(status, reply)
            else:
                self._send(404, {})

    server = HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, state


def run_apply(server):
    argv = ["grant-allocate-to.py", "--base", "http://127.0.0.1:%d" % server.server_port,
            "--firm", "Main", "--apply", "--settle", "0", "--timeout", "5"]
    out = io.StringIO()
    old_argv, old_token = sys.argv, os.environ.get("IAM_ADMIN_API_TOKEN")
    os.environ["IAM_ADMIN_API_TOKEN"] = "fake-token-for-local-test"
    sys.argv = argv
    try:
        with contextlib.redirect_stdout(out):
            code = script.main()
    finally:
        sys.argv = old_argv
        if old_token is None:
            os.environ.pop("IAM_ADMIN_API_TOKEN", None)
        else:
            os.environ["IAM_ADMIN_API_TOKEN"] = old_token
        server.shutdown()
    return code, out.getvalue()


class ApplyAlreadyGrantedTests(unittest.TestCase):
    def test_success_200(self):
        server, state = make_server((200, {}))
        code, out = run_apply(server)
        self.assertEqual(code, 0, out)
        self.assertIn("加入 " + TO_PERM + "：OK", out)
        self.assertEqual(state["posts"], [("/roles/r1/add-permissions", {"permissions": [TO_PERM]})])

    def test_permissions_unchanged_is_skipped(self):
        server, _ = make_server((422, {"error": "permissionsUnchanged"}))
        code, out = run_apply(server)
        self.assertEqual(code, 0, out)
        self.assertIn("視為完成", out)
        self.assertNotIn("失敗", out)

    def test_permission_already_exists_is_skipped(self):
        server, _ = make_server((422, {"error": "permissionAlreadyExists"}))
        code, out = run_apply(server)
        self.assertEqual(code, 0, out)
        self.assertIn("視為完成", out)
        self.assertNotIn("失敗", out)

    def test_other_errors_still_fail(self):
        server, _ = make_server((422, {"error": "roleNotFound"}))
        code, out = run_apply(server)
        self.assertEqual(code, 1, out)
        self.assertIn("失敗：HTTP 422 roleNotFound", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
