import json
import os
import selectors
import stat
import subprocess
import tempfile
from pathlib import Path


class RepositoryPolicy:
    def __init__(self, root: Path):
        self.root = root

    def load(self):
        self.readme = (self.root / "README.md").read_text()
        manual_setup = self.root / "docs/manual-setup.md"
        self.manual_setup = manual_setup.read_text() if manual_setup.exists() else ""
        self.docs = self.readme + "\n" + self.manual_setup
        self.entrypoint = (self.root / "csb/entrypoint.sh").read_text()
        self.containerfile = (self.root / "csb/Containerfile").read_text()
        self.policy = (self.root / "csb/policy.yaml").read_text()
        self.google_workspace_profile = (
            self.root / "csb/providers/google-workspace-gog.yaml"
        ).read_text()
        self.anthropic_profile = (
            self.root / "csb/providers/anthropic-api-key.yaml"
        ).read_text()
        self.quickstart = (self.root / "scripts/openclaw-csb").read_text()
        self.openai_api_key_option = self.root / "scripts/options/openai-api-key"
        self.anthropic_api_key_option = self.root / "scripts/options/anthropic-api-key"
        self.google_workspace_option = (
            self.root / "scripts/options/google-workspace"
        ).read_text()
        self.gemini_option = (self.root / "scripts/options/gemini").read_text()
        self.google_workspace_dashboard = (
            self.root / "csb/skills/google-workspace-dashboard/SKILL.md"
        ).read_text()
        install_policy = self.root / "csb/openclaw-install-policy"
        self.install_policy = install_policy.read_text() if install_policy.exists() else ""
        self.configure_script = self.root / "csb/configure-openclaw.mjs"

    def _run_config(self, extra_env=None, initial_config=None, env_text=None):
        temp_dir = tempfile.TemporaryDirectory()
        config_dir = Path(temp_dir.name)
        config_path = config_dir / "openclaw.json"
        if initial_config is not None:
            config_path.write_text(initial_config)
            os.link(config_path, config_dir / "prior-openclaw.json")
        if env_text is not None:
            (config_dir / ".env").write_text(env_text)

        env = {key: os.environ[key] for key in ("PATH", "SYSTEMROOT", "PATHEXT") if key in os.environ}
        env["OPENCLAW_STATE_DIR"] = str(config_dir)
        env["OPENCLAW_CONFIG_PATH"] = str(config_path)
        env["OPENCLAW_WORKSPACE_DIR"] = str(config_dir / "workspace")
        env.update(extra_env or {})

        try:
            result = subprocess.run(
                ["node", str(self.configure_script)],
                capture_output=True,
                text=True,
                env=env,
                timeout=10,
                check=False,
            )
        except BaseException:
            temp_dir.cleanup()
            raise
        return temp_dir, config_dir, config_path, result

    def _valid_config(self, extra_env=None, initial_config=None, env_text=None):
        env = {
            "OPENCLAW_GATEWAY_TOKEN": "fresh-token",
            "OPENCLAW_ALLOWED_SKILLS": '["team-prs"]',
        }
        env.update(extra_env or {})
        return self._run_config(env, initial_config, env_text)

    def assert_exec_is_fully_permitted(self):
        temp, _, config_path, result = self._valid_config()
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["tools"]["exec"]["mode"] == "full"
            assert config["tools"]["elevated"]["enabled"] is False
        finally:
            temp.cleanup()

    def assert_cron_is_enabled(self):
        temp, _, config_path, result = self._valid_config()
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["cron"]["enabled"] is True
        finally:
            temp.cleanup()

    def assert_skill_visibility_is_explicit(self):
        temp, _, config_path, result = self._valid_config()
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["agents"]["defaults"]["skills"] == ["team-prs"]
        finally:
            temp.cleanup()

        temp, _, config_path, result = self._valid_config(
            {"OPENCLAW_ALLOWED_SKILLS": "[]"}
        )
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["agents"]["defaults"]["skills"] == []
        finally:
            temp.cleanup()

    def assert_runtime_installs_fail_closed(self):
        result = subprocess.run(
            [str(self.root / "csb/openclaw-install-policy")],
            input='{"target":"skill"}',
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        response = json.loads(result.stdout)
        assert result.returncode == 0
        assert response["protocolVersion"] == 1
        assert response["decision"] == "block"
        assert "runtime skill and plugin installation" in response["reason"]
        assert "COPY csb/openclaw-install-policy /usr/local/bin/openclaw-install-policy" in self.containerfile

        temp, _, config_path, config_result = self._valid_config()
        try:
            assert config_result.returncode == 0, config_result.stderr
            config = json.loads(config_path.read_text())
            policy = config["security"]["installPolicy"]
            assert policy["targets"] == ["skill", "plugin"]
            assert policy["exec"]["command"] == "/usr/local/bin/openclaw-install-policy"
        finally:
            temp.cleanup()

    def assert_missing_token_fails_closed(self):
        initial = '{"gateway":{"auth":{"token":"stale-token"}}}\n'
        temp, _, config_path, result = self._run_config(initial_config=initial)
        try:
            assert result.returncode != 0
            assert "OPENCLAW_GATEWAY_TOKEN is required" in result.stderr
            assert config_path.read_text() == initial
        finally:
            temp.cleanup()

    def assert_invalid_inputs_preserve_config(self):
        invalid_environments = [
            ({"OPENCLAW_PUBLIC_URL": "https://openclaw.example/path"}, "OPENCLAW_PUBLIC_URL"),
            ({"OPENCLAW_PUBLIC_URL": "https://user:secret@openclaw.example"}, "OPENCLAW_PUBLIC_URL"),
            ({"OPENCLAW_PROVIDERS": "[]"}, "OPENCLAW_PROVIDERS"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"openai": {"api": "openai-responses", "baseUrl": "not-a-url"}}
                )
            }, "baseUrl"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"openai": {"api": "openai-responses", "baseUrl": "https://api.openai.com", "apiKey": 7}}
                )
            }, "apiKey"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"openai": {"api": "openai-responses", "baseUrl": "https://api.openai.com", "models": [{"id": "gpt-5"}]}}
                )
            }, "names"),
            ({
                "OPENCLAW_PROVIDERS": json.dumps(
                    {"constructor": {"api": "openai-responses", "baseUrl": "https://api.openai.com"}}
                )
            }, "name"),
        ]
        for invalid_env, expected_error in invalid_environments:
            initial = '{"sentinel":"last-valid"}\n'
            temp, config_dir, config_path, result = self._valid_config(
                invalid_env, initial_config=initial
            )
            try:
                assert result.returncode != 0, invalid_env
                assert expected_error in result.stderr
                assert config_path.read_text() == initial
                assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            finally:
                temp.cleanup()

        for initial in (
            '{"gateway":[]}\n',
            '{"gateway":{"auth":[]}}\n',
            '{"plugins":[]}\n',
            '{"tools":[]}\n',
        ):
            temp, config_dir, config_path, result = self._valid_config(initial_config=initial)
            try:
                assert result.returncode != 0, initial
                assert "must be a JSON object" in result.stderr
                assert config_path.read_text() == initial
                assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            finally:
                temp.cleanup()

        result = subprocess.run(
            ["node", str(self.configure_script)],
            capture_output=True,
            text=True,
            env={
                "PATH": os.environ["PATH"],
                "OPENCLAW_GATEWAY_TOKEN": "fresh-token",
            },
            timeout=10,
            check=False,
        )
        assert result.returncode != 0
        assert "OPENCLAW_STATE_DIR" in result.stderr

    def assert_valid_inputs_produce_protected_config(self):
        providers = {
            "openai": {
                "api": "openai-responses",
                "baseUrl": "https://api.openai.com/v1",
                "apiKey": "${OPENAI_API_KEY}",
                "models": [{"id": "gpt-5", "name": "GPT-5"}],
            }
        }
        initial = '{"gateway":{"auth":{"token":"stale-token"}}}\n'
        env_text = (
            "OPENCLAW_GATEWAY_TOKEN=legacy-token\n"
            "OPENAI_API_KEY=preserve-me\n"
            "NODE_ENV=production\n"
        )
        temp, config_dir, config_path, result = self._valid_config(
            {
                "OPENCLAW_PUBLIC_URL": "https://openclaw.example",
                "OPENCLAW_PROVIDERS": json.dumps(providers),
            },
            initial_config=initial,
            env_text=env_text,
        )
        try:
            assert result.returncode == 0, result.stderr
            prior_path = config_dir / "prior-openclaw.json"
            assert prior_path.read_text() == initial
            assert config_path.stat().st_ino != prior_path.stat().st_ino
            config = json.loads(config_path.read_text())
            assert config["gateway"]["auth"]["token"] == "fresh-token"
            assert config["gateway"]["auth"]["rateLimit"] == {
                "maxAttempts": 10,
                "windowMs": 60000,
                "lockoutMs": 300000,
            }
            assert config["gateway"]["bind"] == "lan"
            assert config["gateway"]["controlUi"]["allowedOrigins"] == [
                "http://localhost:18789",
                "http://127.0.0.1:18789",
                "https://openclaw.example",
            ]
            assert config["models"]["providers"]["openai"] == {
                "api": "openai-responses",
                "baseUrl": "https://api.openai.com/v1",
                "apiKey": "${OPENAI_API_KEY}",
                "models": [{"id": "gpt-5", "name": "GPT-5"}],
            }
            assert config["tools"]["exec"]["mode"] == "full"
            assert config["agents"]["defaults"]["skills"] == ["team-prs"]
            assert stat.S_IMODE(config_path.stat().st_mode) == 0o600
            assert list(config_dir.glob(".openclaw.json.*.tmp")) == []
            sanitized_env = (config_dir / ".env").read_text()
            assert "OPENCLAW_GATEWAY_TOKEN=" not in sanitized_env
            assert "OPENAI_API_KEY=preserve-me" in sanitized_env
            assert "NODE_ENV=production" in sanitized_env
        finally:
            temp.cleanup()

    def assert_openai_api_key_configures_inference_local(self):
        assert 'ARG OPENCLAW_EXTENSIONS="anthropic,openai,codex,google"' in self.containerfile
        result = subprocess.run(
            [str(self.openai_api_key_option), "quickstart-args"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        option_args = result.stdout.splitlines()
        assert option_args == [
            "--inference-provider",
            "openai",
            "--inference-model",
            "gpt-5.6-sol",
            "--model-providers",
            '{"openai":{"api":"openai-responses","baseUrl":"https://inference.local/v1","apiKey":"unused","models":[{"id":"gpt-5.6-sol","name":"GPT-5.6 Sol"}]}}',
            "--allow-plugin",
            "openai",
            "--allow-plugin",
            "codex",
            "--default-model",
            "openai/gpt-5.6-sol",
        ]
        model_providers = option_args[5]
        temp, _, config_path, result = self._valid_config(
            {
                "OPENCLAW_PROVIDERS": model_providers,
                "OPENCLAW_ALLOWED_PLUGINS": '["openai","codex"]',
                "OPENCLAW_DEFAULT_MODEL": "openai/gpt-5.6-sol",
            }
        )
        try:
            assert result.returncode == 0, result.stderr
            config_text = config_path.read_text()
            config = json.loads(config_text)
            openai = config["models"]["providers"]["openai"]
            assert openai["baseUrl"] == "https://inference.local/v1"
            assert openai["apiKey"] == "unused"
            assert openai["models"] == [
                {"id": "gpt-5.6-sol", "name": "GPT-5.6 Sol"}
            ]
            assert config["agents"]["defaults"]["model"]["primary"] == (
                "openai/gpt-5.6-sol"
            )
            assert config["plugins"]["allow"] == ["openai", "codex"]
            assert config["plugins"]["entries"]["openai"]["enabled"] is True
            assert config["plugins"]["entries"]["codex"]["enabled"] is True
            assert "inference set" in self.quickstart
        finally:
            temp.cleanup()

    def assert_brokered_anthropic_api_key_configures_claude(self):
        assert "id: anthropic-api-key" in self.anthropic_profile
        assert "env_vars: [ANTHROPIC_API_KEY]" in self.anthropic_profile
        assert "host: api.anthropic.com" in self.anthropic_profile
        assert "  - /usr/bin/node" in self.anthropic_profile
        result = subprocess.run(
            [str(self.anthropic_api_key_option), "quickstart-args"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        assert result.returncode == 0, result.stderr
        assert result.stdout.splitlines() == [
            "--provider",
            "anthropic",
            "--allow-plugin",
            "anthropic",
            "--default-model",
            "anthropic/claude-opus-4-8",
        ]
        api_key = "brokered-anthropic-key-must-not-be-persisted"
        temp, _, config_path, result = self._valid_config(
            {
                "ANTHROPIC_API_KEY": api_key,
                "OPENCLAW_ALLOWED_PLUGINS": '["anthropic"]',
                "OPENCLAW_DEFAULT_MODEL": "anthropic/claude-opus-4-8",
            }
        )
        try:
            assert result.returncode == 0, result.stderr
            config_text = config_path.read_text()
            config = json.loads(config_text)
            assert api_key not in config_text
            assert config["models"]["providers"] == {}
            assert config["agents"]["defaults"]["model"]["primary"] == (
                "anthropic/claude-opus-4-8"
            )
            assert config["plugins"]["allow"] == ["anthropic"]
            assert config["plugins"]["entries"]["anthropic"]["enabled"] is True
        finally:
            temp.cleanup()

    def assert_managed_config_path_is_supported(self):
        assert 'export OPENCLAW_STATE_DIR="${CONFIG_DIR}"' in self.entrypoint
        assert 'export OPENCLAW_CONFIG_PATH="${CONFIG_DIR}/openclaw.json"' in self.entrypoint
        assert "ENV OPENCLAW_STATE_DIR=" not in self.containerfile
        assert "OPENCLAW_CONFIG_PATH=/sandbox/.openclaw/openclaw.json" not in self.containerfile
        assert "OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw" in self.docs
        assert "OPENCLAW_CONFIG_DIR=/sandbox/persist/.openclaw" not in self.docs
        assert 'chmod 700 "${CONFIG_DIR}" "${WORKSPACE_DIR}"' in self.entrypoint
        assert "export TMPDIR=/tmp" in self.entrypoint

    def assert_runtime_install_denial_is_immediate(self):
        process = subprocess.Popen(
            [str(self.root / "csb/openclaw-install-policy")],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        selector = selectors.DefaultSelector()
        try:
            selector.register(process.stdout, selectors.EVENT_READ)
            process.stdin.write('{"target":"plugin"}\n')
            process.stdin.flush()
            assert selector.select(timeout=1), "install-policy waited for stdin EOF"
            response = json.loads(process.stdout.readline())
            assert response["decision"] == "block"
        finally:
            selector.close()
            process.kill()
            process.wait(timeout=2)

    def assert_build_inputs_are_immutable(self):
        assert "ARG CSB_BASE_IMAGE=quay.io/redhat-et/openshell:base-2026.07.16@sha256:15146a75be5d581d9809282c3368829e6c6ff93ea492fd9df5fe2718c478de6c" in self.containerfile
        assert "FROM registry.access.redhat.com/hi/nodejs@sha256:52ea553eff206e75c3dec4ab689c7daa49ec3b81103f2b26e7b82cc7800f61ce AS builder" in self.containerfile
        assert "ARG OPENCLAW_COMMIT=01e6bef816e314d8fde6be21741c5a1ed08eac1c" in self.containerfile
        assert 'test "$(git rev-parse HEAD)" = "${OPENCLAW_COMMIT}"' in self.containerfile
        assert "pnpm install --frozen-lockfile" in self.containerfile
        assert "--no-frozen-lockfile" not in self.containerfile
        assert "find node_modules -type l" in self.containerfile
        assert "find node_modules -maxdepth 3 -type l" not in self.containerfile
        assert "COPY --from=builder --chown=0:0 /build /app" in self.containerfile
        assert "openclaw --version" in self.containerfile

    def assert_google_workspace_is_brokered_through_gog(self):
        assert "ARG GOGCLI_VERSION=0.37.0" in self.containerfile
        assert "id: google-workspace-gog" in self.google_workspace_profile
        assert "env_vars: [GOG_ACCESS_TOKEN]" in self.google_workspace_profile
        assert "strategy: oauth2_refresh_token" in self.google_workspace_profile
        for host in ("gmail.googleapis.com", "www.googleapis.com"):
            assert f"host: {host}" in self.google_workspace_profile
        assert "path: /drive/v3/**" not in self.google_workspace_profile
        assert "path: /calendar/v3/**" in self.google_workspace_profile
        assert self.google_workspace_profile.count("access: read-only") == 1
        assert self.google_workspace_profile.count("access: read-write") == 1
        assert "  - /usr/local/bin/gog" in self.google_workspace_profile
        assert (
            "${OPENCLAW_CSB_GOOGLE_WORKSPACE_PROVIDER_NAME:-gog-google-workspace}"
            in self.google_workspace_option
        )
        google_workspace_option_result = subprocess.run(
            [str(self.root / "scripts/options/google-workspace"), "quickstart-args"],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        assert google_workspace_option_result.returncode == 0, google_workspace_option_result.stderr
        assert google_workspace_option_result.stdout.splitlines() == [
            "--provider",
            "gog-google-workspace",
            "--image-skill",
            "gog",
            "--image-skill",
            "google-workspace-dashboard",
        ]
        assert "${OPENCLAW_CSB_GEMINI_PROVIDER_NAME:-gemini}" in self.gemini_option
        assert 'create_args+=(--provider "${providers[$index]}")' in self.quickstart
        assert 'cp -R "/app/skills/${skill_name}"' in self.quickstart
        assert "GOG_READONLY" not in self.quickstart
        assert "--provider openai" not in self.quickstart
        assert "--provider github" not in self.quickstart

    def assert_native_google_workspace_widgets_are_available(self):
        assert "COPY --chown=0:0 csb/skills /app/skills" in self.containerfile
        assert "EXPOSE 18789 18790" in self.containerfile
        for asset in (
            "google-workspace-dashboard.html",
            "daily-briefing-dashboard.html",
            "presentation-studio-dashboard.html",
        ):
            assert (
                self.root
                / "csb/skills/google-workspace-dashboard/assets"
                / asset
            ).is_file()
        assert 'capabilities.tools: ["prompt"]' in self.google_workspace_dashboard
        assert "Do not add network capabilities" in self.google_workspace_dashboard
        assert 'WIDGET_PORT="${OPENCLAW_CSB_WIDGET_PORT:-18790}"' in self.quickstart
        assert "config?.mcp?.apps?.sandboxPort" in self.quickstart
        assert "resolve_widget_port_from_sandbox\n    ensure_forward" in self.quickstart
        assert 'ssh-proxy --gateway-name ${gateway_name}' in self.quickstart
        assert '-L "127.0.0.1:${WIDGET_PORT}:127.0.0.1:${WIDGET_PORT}"' in self.quickstart
        assert "nohup openshell forward service" not in self.quickstart
        assert '--env "OPENCLAW_WIDGET_PORT=${WIDGET_PORT}"' in self.quickstart

        temp, _, config_path, result = self._valid_config(
            {"OPENCLAW_WIDGET_PORT": "18791"}
        )
        try:
            assert result.returncode == 0, result.stderr
            config = json.loads(config_path.read_text())
            assert config["mcp"]["apps"] == {
                "enabled": False,
                "sandboxPort": 18791,
            }
            assert "canvas" not in config["tools"]["deny"]
        finally:
            temp.cleanup()

    def assert_helper_manages_gateway_lifecycle(self):
        for action in ("start", "stop", "restart", "status"):
            assert f"gateway {action}" in self.quickstart
        assert '"node /app/dist/index.js gateway "*' in self.quickstart
        assert 'kill -TERM "${process_dir##*/}"' in self.quickstart
        assert "nohup /app/entrypoint.sh >/tmp/openclaw-gateway.log 2>&1" in self.quickstart
        assert "stop_gateway\n            start_gateway" in self.quickstart
        assert "openshell sandbox delete" not in self.quickstart
        assert "podman volume rm" not in self.quickstart

    def assert_production_dependency_selection_fails_closed(self):
        selection_command = "RUN pnpm install --prod --offline --frozen-lockfile"
        selection_position = self.containerfile.index(selection_command)
        source_removal_position = self.containerfile.index(
            "RUN rm -rf extensions/ packages/ patches/"
        )
        link_resolution_position = self.containerfile.index(
            "RUN find node_modules -type l"
        )
        assert selection_position < link_resolution_position < source_removal_position
        selection_block = self.containerfile[
            selection_position:source_removal_position
        ]
        assert "|| true" not in selection_block.split("\n", 1)[0]

    def assert_openshell_policy_is_canonical(self):
        expected = """version: 1
filesystem_policy:
  include_workdir: true
  read_only:
    - /usr
    - /lib
    - /proc
    - /dev/urandom
    - /app
    - /etc
    - /var/log
  read_write:
    - /sandbox
    - /tmp
    - /dev/null
    # Required by forkpty/openpty for OpenClaw's interactive terminal sessions.
    - /dev/pts
landlock:
  compatibility: best_effort
process:
  run_as_user: sandbox
  run_as_group: sandbox
network_policies:
  github_api:
    name: github-api-readonly
    endpoints:
      - host: api.github.com
        port: 443
        access: read-only
        protocol: rest
        enforcement: enforce
    binaries:
      - path: /usr/bin/curl
"""
        assert self.policy == expected

    def assert_readme_is_reproducible(self):
        deployment_required = [
            "podman volume create openclaw-csb-data",
            '"podman":{"mounts"',
            '"source":"openclaw-csb-data"',
            '"target":"/sandbox/persist"',
            "chmod 0777 /data",
            "--policy csb/policy.yaml",
            "--cpu 2",
            "--memory 4Gi",
            "ssh-proxy --gateway-name",
            "OPENCLAW_ALLOWED_SKILLS",
            "OPENCLAW_STATE_DIR=/sandbox/persist/.openclaw",
            "OPENCLAW_WORKSPACE_DIR=/sandbox/persist/workspace",
        ]
        for text in deployment_required:
            assert text in self.docs, f"Docs are missing: {text}"
        validation_required = [
            "openshell sandbox get openclaw-csb --policy-only",
            "config get agents.defaults.skills",
            "config get tools.exec.mode",
        ]
        for text in validation_required:
            assert text in self.readme, f"README is missing: {text}"
        assert "OPENCLAW_AI_ENV_VAR" not in self.docs
