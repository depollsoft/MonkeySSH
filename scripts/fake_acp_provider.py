#!/usr/bin/env python3
"""Deterministic, credential-free ACP v1 provider for MonkeySSH validation.

Modes:
  (default)        Advertises one ``agent`` auth method and never requires it.
  --require-auth   Rejects session setup with ``auth_required`` (-32000) until
                   the ``fake-agent-login`` method is authenticated over ACP or
                   the ``fake-terminal-login`` terminal method has run. Also
                   advertises ``agentCapabilities.auth.logout``.
  --login          Interactive login-only flow run by a client for the
                   terminal method. Requires ``FAKE_ACP_LOGIN=1`` (the method's
                   env), asks for Enter, records the sign-in, and exits 0.

The terminal sign-in is shared through ``FAKE_ACP_AUTH_FILE`` (default: a file
in the system temp directory). No real credentials are read or written.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from typing import Any

MAX_INLINE_BYTES = 64 * 1024
PNG_1X1 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk"
    "+A8AAQUBAScY42YAAAAASUVORK5CYII="
)
PERMISSION_OPTIONS = [
    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
    {"optionId": "allow-always", "name": "Always allow", "kind": "allow_always"},
    {"optionId": "reject-once", "name": "Reject once", "kind": "reject_once"},
    {
        "optionId": "reject-always",
        "name": "Always reject",
        "kind": "reject_always",
    },
]


AUTH_REQUIRED = -32000
AGENT_LOGIN_METHOD = "fake-agent-login"
TERMINAL_LOGIN_METHOD = "fake-terminal-login"
TERMINAL_LOGIN_ENV = "FAKE_ACP_LOGIN"
AUTH_SETUP_METHODS = {
    "session/new",
    "session/list",
    "session/load",
    "session/resume",
    "session/prompt",
}


def auth_file_path() -> str:
    """Return the marker shared by the terminal login and later providers."""
    return os.environ.get("FAKE_ACP_AUTH_FILE") or os.path.join(
        tempfile.gettempdir(), "monkeyssh-fake-acp-auth"
    )


def run_terminal_login() -> int:
    """Run the interactive login-only flow for the terminal auth method."""
    if os.environ.get(TERMINAL_LOGIN_ENV) != "1":
        sys.stderr.write(f"{TERMINAL_LOGIN_ENV}=1 is required for --login\n")
        return 2
    sys.stdout.write("MonkeySSH fake ACP sign-in\n")
    sys.stdout.write(
        "Visit https://example.invalid/fake-device and enter code FAKE-1234\n"
    )
    sys.stdout.write("Press Enter to finish signing in (type 'no' to cancel): ")
    sys.stdout.flush()
    answer = sys.stdin.readline()
    if not answer or answer.strip().lower() == "no":
        sys.stdout.write("\nSign-in canceled.\n")
        return 1
    with open(auth_file_path(), "w", encoding="utf-8") as marker:
        marker.write("signed-in\n")
    sys.stdout.write("Signed in.\n")
    return 0


class FakeAcpProvider:
    """Small stateful ACP provider with deterministic fixtures."""

    def __init__(self, *, require_auth: bool = False) -> None:
        self.require_auth = require_auth
        self.agent_authenticated = False
        self.client_terminal_auth = False
        self.sessions: dict[str, dict[str, Any]] = {}
        self.next_session = 1
        self.next_permission = 1
        self.pending_prompts: dict[str, dict[str, Any]] = {}
        self.pending_permissions: dict[str, str] = {}
        self.next_elicitation = 1
        self.pending_elicitations: dict[str, dict[str, Any]] = {}
        self.withdrawn_permissions: dict[str, str] = {}
        self.elicitation_modes: set[str] = set()
        self.client_terminal = False
        self.next_terminal_step = 1
        self.terminal_steps: dict[str, dict[str, Any]] = {}

    def write(self, message: dict[str, Any]) -> None:
        encoded = json.dumps(message, separators=(",", ":"), sort_keys=True)
        if len(encoded.encode("utf-8")) > MAX_INLINE_BYTES:
            raise ValueError("fake provider attempted an oversized frame")
        sys.stdout.write(encoded + "\n")
        sys.stdout.flush()

    def result(self, request_id: Any, result: Any = None) -> None:
        self.write({"jsonrpc": "2.0", "id": request_id, "result": result or {}})

    def error(self, request_id: Any, code: int, message: str) -> None:
        self.write(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "error": {"code": code, "message": message},
            }
        )

    def update(
        self,
        session_id: str,
        update: dict[str, Any],
        *,
        record: bool = False,
    ) -> None:
        self.write(
            {
                "jsonrpc": "2.0",
                "method": "session/update",
                "params": {"sessionId": session_id, "update": update},
            }
        )
        if record and update.get("sessionUpdate") in {
            "user_message_chunk",
            "agent_message_chunk",
            "agent_thought_chunk",
        }:
            self.sessions[session_id]["history"].append(update)

    @staticmethod
    def config_options(session: dict[str, Any]) -> list[dict[str, Any]]:
        return [
            {
                "id": "responseStyle",
                "name": "Response style",
                "description": "Controls the deterministic response length.",
                "category": "fake",
                "type": "select",
                "currentValue": session["responseStyle"],
                "options": [
                    {"value": "concise", "name": "Concise"},
                    {"value": "detailed", "name": "Detailed"},
                ],
            },
            {
                "id": "safeMode",
                "name": "Safe mode",
                "description": "Requires the exact permission fixture.",
                "category": "fake",
                "type": "boolean",
                "currentValue": session["safeMode"],
            },
        ]

    def setup_result(self, session_id: str) -> dict[str, Any]:
        session = self.sessions[session_id]
        return {
            "sessionId": session_id,
            "configOptions": self.config_options(session),
            "modes": {
                "currentModeId": "fixture",
                "availableModes": [{"id": "fixture", "name": "Fixture"}],
            },
            "models": {
                "currentModelId": "fake-acp-v1",
                "availableModels": [
                    {"id": "fake-acp-v1", "name": "Fake ACP v1"}
                ],
            },
        }

    def commands_update(self, session_id: str) -> None:
        self.update(
            session_id,
            {
                "sessionUpdate": "available_commands_update",
                "availableCommands": [
                    {
                        "name": "echo",
                        "description": "Echo deterministic text.",
                        "input": {"type": "unstructured", "hint": "text"},
                    },
                    {
                        "name": "fixtures",
                        "description": "Emit every ACP fixture.",
                    },
                    {
                        "name": "wait",
                        "description": "Wait until session/cancel.",
                    },
                    {
                        "name": "elicit",
                        "description": "Ask for structured input.",
                    },
                    {
                        "name": "elicit-url",
                        "description": "Ask the user to open a page.",
                    },
                    {
                        "name": "cancel-permission",
                        "description": "Request and then withdraw a permission.",
                    },
                    {
                        "name": "terminal",
                        "description": "Run a command in a client terminal.",
                    },
                ],
            },
        )

    def create_session(self, cwd: str) -> str:
        session_id = f"fake-session-{self.next_session:04d}"
        self.next_session += 1
        self.sessions[session_id] = {
            "cwd": cwd,
            "title": f"Fake session {self.next_session - 1}",
            "history": [],
            "responseStyle": "concise",
            "safeMode": True,
        }
        return session_id

    def require_session(self, request_id: Any, params: dict[str, Any]) -> str | None:
        session_id = params.get("sessionId")
        if not isinstance(session_id, str) or session_id not in self.sessions:
            self.error(request_id, -32001, "unknown fake session")
            return None
        return session_id

    def is_authenticated(self) -> bool:
        return self.agent_authenticated or os.path.exists(auth_file_path())

    def auth_methods(self) -> list[dict[str, Any]]:
        if not self.require_auth:
            return [
                {
                    "id": "fake-local",
                    "name": "Local deterministic fixture",
                    "type": "agent",
                    "description": "No credentials or network access.",
                }
            ]
        methods: list[dict[str, Any]] = [
            {
                "id": AGENT_LOGIN_METHOD,
                "name": "Fake agent sign-in",
                "description": "Completes immediately over ACP.",
            }
        ]
        # Terminal methods are advertised only to clients that can run them.
        if self.client_terminal_auth:
            methods.append(
                {
                    "id": TERMINAL_LOGIN_METHOD,
                    "name": "Fake terminal sign-in",
                    "type": "terminal",
                    "description": "Press Enter in the terminal to sign in.",
                    "args": ["--login"],
                    "env": {TERMINAL_LOGIN_ENV: "1"},
                }
            )
        return methods

    def handle_request(self, message: dict[str, Any]) -> None:
        request_id = message.get("id")
        method = message.get("method")
        params = message.get("params") or {}

        if (
            self.require_auth
            and method in AUTH_SETUP_METHODS
            and not self.is_authenticated()
        ):
            self.error(request_id, AUTH_REQUIRED, "Authentication required")
            return

        if method == "initialize":
            client_capabilities = params.get("clientCapabilities") or {}
            elicitation = client_capabilities.get("elicitation") or {}
            self.elicitation_modes = {
                mode
                for mode in ("form", "url")
                if isinstance(elicitation, dict) and elicitation.get(mode) is not None
            }
            auth_capabilities = client_capabilities.get("auth") or {}
            self.client_terminal_auth = auth_capabilities.get("terminal") is True
            self.client_terminal = client_capabilities.get("terminal") is True
            capabilities: dict[str, Any] = {
                "loadSession": True,
                "promptCapabilities": {
                    "image": True,
                    "audio": False,
                    "embeddedContext": True,
                },
                "sessionCapabilities": {
                    "list": {},
                    "resume": {},
                    "close": {},
                },
            }
            if self.require_auth:
                capabilities["auth"] = {"logout": {}}
            self.result(
                request_id,
                {
                    "protocolVersion": 1,
                    "agentInfo": {
                        "name": "monkeyssh-fake-acp",
                        "title": "MonkeySSH Fake ACP",
                        "version": "1.0.0",
                    },
                    "agentCapabilities": capabilities,
                    "authMethods": self.auth_methods(),
                },
            )
        elif method == "authenticate":
            method_id = params.get("methodId")
            if not self.require_auth and method_id == "fake-local":
                self.result(request_id)
            elif self.require_auth and method_id == AGENT_LOGIN_METHOD:
                self.agent_authenticated = True
                self.result(request_id)
            elif method_id == TERMINAL_LOGIN_METHOD:
                self.error(
                    request_id,
                    -32602,
                    "terminal methods are completed outside the ACP connection",
                )
            else:
                self.error(request_id, -32002, "unsupported auth method")
        elif method == "logout":
            if not self.require_auth:
                self.error(request_id, -32601, "method not found: logout")
                return
            self.agent_authenticated = False
            try:
                os.remove(auth_file_path())
            except FileNotFoundError:
                pass
            self.result(request_id)
        elif method == "session/new":
            session_id = self.create_session(str(params.get("cwd") or "."))
            self.result(request_id, self.setup_result(session_id))
            self.commands_update(session_id)
        elif method == "session/list":
            sessions = [
                {
                    "sessionId": session_id,
                    "cwd": session["cwd"],
                    "title": session["title"],
                    "updatedAt": "2026-01-01T00:00:00Z",
                }
                for session_id, session in sorted(self.sessions.items())
            ]
            self.result(request_id, {"sessions": sessions})
        elif method in {"session/load", "session/resume"}:
            session_id = self.require_session(request_id, params)
            if session_id is None:
                return
            if method == "session/load":
                for recorded in self.sessions[session_id]["history"]:
                    replayed = dict(recorded)
                    replayed["_meta"] = {"replayed": True}
                    self.update(session_id, replayed)
            self.result(request_id, self.setup_result(session_id))
            self.commands_update(session_id)
        elif method == "session/close":
            session_id = self.require_session(request_id, params)
            if session_id is not None:
                self.result(request_id)
        elif method == "session/set_config_option":
            session_id = self.require_session(request_id, params)
            if session_id is None:
                return
            config_id = params.get("configId")
            value = params.get("value")
            if config_id == "responseStyle" and value in {"concise", "detailed"}:
                self.sessions[session_id][config_id] = value
            elif config_id == "safeMode" and isinstance(value, bool):
                self.sessions[session_id][config_id] = value
            else:
                self.error(request_id, -32602, "invalid config option")
                return
            options = self.config_options(self.sessions[session_id])
            self.result(request_id, {"sessionId": session_id, "configOptions": options})
            self.update(
                session_id,
                {"sessionUpdate": "config_option_update", "configOptions": options},
            )
        elif method == "session/prompt":
            self.start_prompt(request_id, params)
        else:
            self.error(request_id, -32601, f"method not found: {method}")

    def start_prompt(self, request_id: Any, params: dict[str, Any]) -> None:
        session_id = self.require_session(request_id, params)
        if session_id is None:
            return
        prompt = params.get("prompt") or []
        text = " ".join(
            block.get("text", "")
            for block in prompt
            if isinstance(block, dict) and block.get("type") == "text"
        ).strip()
        user_update = {
            "sessionUpdate": "user_message_chunk",
            "messageId": f"user-{request_id}",
            "content": {"type": "text", "text": text or "(attachment fixture)"},
        }
        self.update(session_id, user_update, record=True)
        self.update(
            session_id,
            {
                "sessionUpdate": "agent_thought_chunk",
                "messageId": f"thought-{request_id}",
                "content": {
                    "type": "text",
                    "text": "Deterministically evaluating the fixture.",
                },
            },
            record=True,
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "plan",
                "entries": [
                    {
                        "content": "Validate ACP transport",
                        "priority": "high",
                        "status": "in_progress",
                    },
                    {
                        "content": "Return bounded fixtures",
                        "priority": "medium",
                        "status": "pending",
                    },
                ],
            },
        )
        self.pending_prompts[str(request_id)] = {
            "requestId": request_id,
            "sessionId": session_id,
            "text": text,
        }
        if text.startswith("/wait") or text == "wait":
            return
        if text == "/elicit":
            self.start_elicitation(request_id, session_id, "form")
            return
        if text == "/elicit-url":
            self.start_elicitation(request_id, session_id, "url")
            return
        if text == "/cancel-permission":
            self.start_withdrawn_permission(request_id, session_id)
            return
        if text == "/terminal":
            self.start_terminal(request_id, session_id)
            return

        response_text = (
            text.removeprefix("/echo").strip()
            if text.startswith("/echo")
            else "Fake ACP response"
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "agent_message_chunk",
                "messageId": f"assistant-{request_id}",
                "content": {"type": "text", "text": response_text},
            },
            record=True,
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "agent_message_chunk",
                "messageId": f"assistant-{request_id}",
                "content": {
                    "type": "image",
                    "data": PNG_1X1,
                    "mimeType": "image/png",
                    "uri": "fixture://pixel.png",
                },
            },
            record=True,
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "agent_message_chunk",
                "messageId": f"assistant-{request_id}",
                "content": {
                    "type": "resource",
                    "resource": {
                        "uri": "fixture://readme.txt",
                        "mimeType": "text/plain",
                        "text": "bounded fake ACP resource",
                    },
                },
            },
            record=True,
        )
        tool_call = {
            "sessionUpdate": "tool_call",
            "toolCallId": f"tool-{request_id}",
            "title": "Read deterministic fixture",
            "kind": "read",
            "status": "pending",
            "locations": [{"path": "fixture/readme.txt", "line": 1}],
            "rawInput": {"fixture": True},
        }
        self.update(session_id, tool_call)
        permission_id = f"fake-permission-{self.next_permission:04d}"
        self.next_permission += 1
        self.pending_permissions[permission_id] = str(request_id)
        self.write(
            {
                "jsonrpc": "2.0",
                "id": permission_id,
                "method": "session/request_permission",
                "params": {
                    "sessionId": session_id,
                    "toolCall": tool_call,
                    "options": PERMISSION_OPTIONS,
                },
            }
        )

    def start_elicitation(self, request_id: Any, session_id: str, mode: str) -> None:
        if mode not in self.elicitation_modes:
            self.finish_prompt_with_text(
                request_id, session_id, f"elicitation={mode}-unsupported"
            )
            return
        elicitation_id = f"fake-elicit-{self.next_elicitation:04d}"
        self.next_elicitation += 1
        params: dict[str, Any] = {"sessionId": session_id, "mode": mode}
        if mode == "form":
            params["message"] = "Choose how the fixture should proceed."
            params["requestedSchema"] = {
                "type": "object",
                "properties": {
                    "strategy": {
                        "type": "string",
                        "title": "Strategy",
                        "oneOf": [
                            {"const": "safe", "title": "Safe"},
                            {"const": "fast", "title": "Fast"},
                        ],
                        "default": "safe",
                    },
                    "retries": {
                        "type": "integer",
                        "title": "Retries",
                        "minimum": 0,
                        "maximum": 3,
                        "default": 1,
                    },
                    "dryRun": {"type": "boolean", "title": "Dry run"},
                },
                "required": ["strategy"],
            }
        else:
            params["message"] = "Connect the deterministic fixture account."
            params["elicitationId"] = f"fake-oauth-{elicitation_id}"
            params["url"] = (
                "https://example.com/fake-acp/connect?elicitation="
                + elicitation_id
            )
        self.pending_elicitations[elicitation_id] = {
            "prompt": str(request_id),
            "mode": mode,
            "elicitationId": params.get("elicitationId"),
        }
        self.write(
            {
                "jsonrpc": "2.0",
                "id": elicitation_id,
                "method": "elicitation/create",
                "params": params,
            }
        )

    def finish_elicitation(self, message: dict[str, Any]) -> None:
        pending = self.pending_elicitations.pop(str(message.get("id")))
        prompt = self.pending_prompts.get(pending["prompt"])
        if prompt is None:
            return
        result = message.get("result") or {}
        action = result.get("action") if isinstance(result, dict) else None
        if "error" in message:
            action = f"error{message['error'].get('code')}"
        content = result.get("content") if isinstance(result, dict) else None
        if pending["mode"] == "url" and action == "accept":
            self.write(
                {
                    "jsonrpc": "2.0",
                    "method": "elicitation/complete",
                    "params": {"elicitationId": pending["elicitationId"]},
                }
            )
        summary = f"elicitation={action}"
        if content is not None:
            summary += " " + json.dumps(content, separators=(",", ":"), sort_keys=True)
        self.finish_prompt_with_text(prompt["requestId"], prompt["sessionId"], summary)

    def terminal_request(
        self,
        prompt: str,
        stage: str,
        method: str,
        params: dict[str, Any],
        **state: Any,
    ) -> None:
        step_id = f"fake-terminal-{self.next_terminal_step:04d}"
        self.next_terminal_step += 1
        self.terminal_steps[step_id] = {"prompt": prompt, "stage": stage, **state}
        self.write({"jsonrpc": "2.0", "id": step_id, "method": method, "params": params})

    def start_terminal(self, request_id: Any, session_id: str) -> None:
        """Runs a short command in a client terminal and embeds its output.

        Exercises terminal/create, a tool call that embeds the terminal and an
        embedded resource, terminal/wait_for_exit, and terminal/release.
        """
        if not self.client_terminal:
            self.finish_prompt_with_text(
                request_id, session_id, "terminal=unsupported"
            )
            return
        self.terminal_request(
            str(request_id),
            "create",
            "terminal/create",
            {
                "sessionId": session_id,
                "command": "sh",
                "args": [
                    "-c",
                    "printf 'fixture line 1\\n'; sleep 1; printf 'fixture line 2\\n'",
                ],
                "outputByteLimit": 4096,
            },
        )

    def advance_terminal(self, message: dict[str, Any]) -> None:
        step = self.terminal_steps.pop(str(message.get("id")))
        prompt = self.pending_prompts.get(step["prompt"])
        if prompt is None:
            return
        session_id = prompt["sessionId"]
        tool_call_id = f"tool-terminal-{prompt['requestId']}"
        if "error" in message:
            self.finish_prompt_with_text(
                prompt["requestId"],
                session_id,
                f"terminal=error{message['error'].get('code')}",
            )
            return
        result = message.get("result") or {}
        if step["stage"] == "create":
            terminal_id = result.get("terminalId")
            self.update(
                session_id,
                {
                    "sessionUpdate": "tool_call",
                    "toolCallId": tool_call_id,
                    "title": "Run fixture command",
                    "name": "Bash",
                    "kind": "execute",
                    "status": "in_progress",
                    "content": [
                        {"type": "terminal", "terminalId": terminal_id},
                        {
                            "type": "content",
                            "content": {
                                "type": "resource",
                                "resource": {
                                    "uri": "fixture://terminal-notes.md",
                                    "mimeType": "text/markdown",
                                    "text": "# Fixture notes\n\nEmbedded text.",
                                },
                            },
                        },
                    ],
                },
            )
            self.terminal_request(
                step["prompt"],
                "wait",
                "terminal/wait_for_exit",
                {"sessionId": session_id, "terminalId": terminal_id},
                terminalId=terminal_id,
            )
        elif step["stage"] == "wait":
            exit_code = result.get("exitCode")
            self.update(
                session_id,
                {
                    "sessionUpdate": "tool_call_update",
                    "toolCallId": tool_call_id,
                    "status": "completed" if exit_code == 0 else "failed",
                },
            )
            self.terminal_request(
                step["prompt"],
                "release",
                "terminal/release",
                {"sessionId": session_id, "terminalId": step["terminalId"]},
                exitCode=exit_code,
            )
        else:
            self.finish_prompt_with_text(
                prompt["requestId"], session_id, f"terminal=exit {step['exitCode']}"
            )

    def start_withdrawn_permission(self, request_id: Any, session_id: str) -> None:
        permission_id = f"fake-permission-{self.next_permission:04d}"
        self.next_permission += 1
        self.withdrawn_permissions[permission_id] = str(request_id)
        self.write(
            {
                "jsonrpc": "2.0",
                "id": permission_id,
                "method": "session/request_permission",
                "params": {
                    "sessionId": session_id,
                    "toolCall": {
                        "toolCallId": f"tool-{request_id}",
                        "title": "Withdrawn fixture",
                    },
                    "options": PERMISSION_OPTIONS,
                },
            }
        )
        self.write(
            {
                "jsonrpc": "2.0",
                "method": "$/cancel_request",
                "params": {"requestId": permission_id},
            }
        )

    def finish_withdrawn_permission(self, message: dict[str, Any]) -> None:
        prompt_key = self.withdrawn_permissions.pop(str(message.get("id")))
        prompt = self.pending_prompts.get(prompt_key)
        if prompt is None:
            return
        code = (message.get("error") or {}).get("code")
        self.finish_prompt_with_text(
            prompt["requestId"],
            prompt["sessionId"],
            "permission=withdrawn" if code == -32800 else "permission=answered",
        )

    def finish_prompt_with_text(
        self, request_id: Any, session_id: str, text: str
    ) -> None:
        self.pending_prompts.pop(str(request_id), None)
        self.update(
            session_id,
            {
                "sessionUpdate": "agent_message_chunk",
                "messageId": f"assistant-{request_id}",
                "content": {"type": "text", "text": text},
            },
            record=True,
        )
        self.result(request_id, {"stopReason": "end_turn"})

    def cancel_request(self, params: dict[str, Any]) -> None:
        """Answers a client-cancelled prompt with -32800."""
        prompt_key = str(params.get("requestId"))
        pending = self.pending_prompts.pop(prompt_key, None)
        if pending is None:
            return
        for permission_id, candidate in list(self.pending_permissions.items()):
            if candidate == prompt_key:
                self.pending_permissions.pop(permission_id)
        self.error(pending["requestId"], -32800, "Request cancelled")

    def finish_permission(self, message: dict[str, Any]) -> None:
        permission_id = str(message.get("id"))
        prompt_key = self.pending_permissions.pop(permission_id)
        pending = self.pending_prompts.pop(prompt_key)
        outcome = (message.get("result") or {}).get("outcome") or {}
        option_id = outcome.get("optionId")
        valid_ids = {option["optionId"] for option in PERMISSION_OPTIONS}
        if outcome.get("outcome") != "selected" or option_id not in valid_ids:
            option_id = "cancelled"
        session_id = pending["sessionId"]
        rejected = option_id.startswith("reject") or option_id == "cancelled"
        self.update(
            session_id,
            {
                "sessionUpdate": "tool_call_update",
                "toolCallId": f"tool-{pending['requestId']}",
                "status": "failed" if rejected else "completed",
                "content": [
                    {
                        "type": "content",
                        "content": {
                            "type": "text",
                            "text": f"permission={option_id}",
                        },
                    }
                ],
                "rawOutput": {"permissionOptionId": option_id},
            },
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "usage_update",
                "used": 128,
                "size": 4096,
                "cost": {"amount": 0, "currency": "USD"},
            },
        )
        self.update(
            session_id,
            {
                "sessionUpdate": "plan",
                "entries": [
                    {
                        "content": "Validate ACP transport",
                        "priority": "high",
                        "status": "completed",
                    },
                    {
                        "content": "Return bounded fixtures",
                        "priority": "medium",
                        "status": "completed",
                    },
                ],
            },
        )
        self.result(pending["requestId"], {"stopReason": "end_turn"})

    def cancel_prompt(self, params: dict[str, Any]) -> None:
        session_id = params.get("sessionId")
        for prompt_key, pending in list(self.pending_prompts.items()):
            if pending["sessionId"] != session_id:
                continue
            self.pending_prompts.pop(prompt_key)
            for permission_id, candidate in list(self.pending_permissions.items()):
                if candidate == prompt_key:
                    self.pending_permissions.pop(permission_id)
            self.update(
                session_id,
                {
                    "sessionUpdate": "agent_message_chunk",
                    "messageId": f"assistant-{pending['requestId']}",
                    "content": {"type": "text", "text": "Prompt cancelled."},
                },
                record=True,
            )
            self.result(pending["requestId"], {"stopReason": "cancelled"})

    def handle(self, message: dict[str, Any]) -> None:
        message_id = str(message.get("id"))
        if "method" not in message and message_id in self.pending_permissions:
            self.finish_permission(message)
        elif "method" not in message and message_id in self.pending_elicitations:
            self.finish_elicitation(message)
        elif "method" not in message and message_id in self.withdrawn_permissions:
            self.finish_withdrawn_permission(message)
        elif "method" not in message and message_id in self.terminal_steps:
            self.advance_terminal(message)
        elif message.get("method") == "$/cancel_request" and "id" not in message:
            self.cancel_request(message.get("params") or {})
        elif message.get("method") == "session/cancel" and "id" not in message:
            self.cancel_prompt(message.get("params") or {})
        elif "method" in message and "id" in message:
            self.handle_request(message)


def main() -> int:
    arguments = sys.argv[1:]
    if "--login" in arguments:
        return run_terminal_login()
    provider = FakeAcpProvider(require_auth="--require-auth" in arguments)
    for raw_line in sys.stdin:
        if len(raw_line.encode("utf-8")) > MAX_INLINE_BYTES:
            provider.error(None, -32000, "frame exceeds fake provider limit")
            continue
        try:
            message = json.loads(raw_line)
            if not isinstance(message, dict):
                raise ValueError("JSON-RPC frame must be an object")
            provider.handle(message)
        except (json.JSONDecodeError, ValueError) as error:
            provider.error(None, -32700, str(error))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
