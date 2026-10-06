import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[2]
TERRAFORM_ROOTS = ("infra", "infra/export-access", "infra/model-router")


@pytest.fixture(autouse=True)
def _authorize_all_subscriptions_by_default():
    pass


def test_api_container_has_an_explicit_nonroot_source_only_contract():
    lines = (PROJECT_ROOT / "api" / "Dockerfile").read_text().splitlines()
    assert "USER 65532:65532" in lines
    assert "EXPOSE 8000" in lines
    assert "ENTRYPOINT []" in lines
    assert not any(line.startswith("COPY . ") for line in lines)
    assert "COPY --chown=65532:65532 brand.py ./" in lines
    assert any("--constraint constraints.txt" in line for line in lines)
    command = json.loads(next(line.removeprefix("CMD ") for line in lines if line.startswith("CMD ")))
    assert command[:4] == ["/usr/bin/python", "-m", "uvicorn", "main:app"]
    assert "--no-proxy-headers" in command
    assert command[command.index("--port") + 1] == "8000"
    assert "uvicorn[standard]" not in (PROJECT_ROOT / "api" / "requirements.txt").read_text()


def test_api_build_context_excludes_environment_state_and_test_data():
    patterns = (PROJECT_ROOT / "api" / ".dockerignore").read_text().splitlines()
    assert {".venv", ".env", ".env.*", ".azure", ".git", "tests", "manifests", "__pycache__"} <= set(patterns)


def test_container_base_images_are_immutable_and_installer_is_patched():
    images = []
    for service in ("api", "web"):
        lines = (PROJECT_ROOT / service / "Dockerfile").read_text().splitlines()
        images.extend(line.split("=", 1)[1] for line in lines if line.startswith("ARG ") and "_IMAGE=" in line)
    assert len(images) == 4
    assert all(re.fullmatch(r"[a-z0-9/_.:-]+@sha256:[a-f0-9]{64}", image) for image in images)
    api_recipe = (PROJECT_ROOT / "api" / "Dockerfile").read_text()
    assert "pip==26.2.1" in api_recipe
    assert "--only-binary=:all: --target /opt/python" in api_recipe
    assert "cgr.dev/chainguard/python:latest@sha256:" in api_recipe
    assert "sys.version_info[:3] == (3, 14, 7)" in api_recipe
    runtime = api_recipe.split("AS runtime", 1)[1]
    assert "COPY --from=dependencies /opt/python /opt/python" in runtime
    assert "pip install" not in runtime and "RUN " not in runtime


def test_web_image_copies_only_built_assets_into_an_unprivileged_runtime():
    dockerfile = (PROJECT_ROOT / "web" / "Dockerfile").read_text()
    assert "RUN npm ci --no-audit --no-fund" in dockerfile
    assert "RUN npm run build" in dockerfile
    runtime = dockerfile.split("AS runtime", 1)[1]
    assert "USER 101:101" in runtime
    assert "EXPOSE 8080" in runtime
    assert "COPY --from=build --chown=101:101 /app/dist/" in runtime
    assert "node_modules" not in runtime and "npm run dev" not in runtime
    patterns = set((PROJECT_ROOT / "web" / ".dockerignore").read_text().splitlines())
    assert {"node_modules", ".env", ".env.*", "test-results", "browser", "manifests"} <= patterns


def test_web_proxy_reaches_the_in_cluster_api_and_strips_forged_identity_headers():
    configuration = (PROJECT_ROOT / "web" / "nginx" / "default.conf.template").read_text()
    assert "proxy_pass http://${API_HOST};" in configuration
    assert "proxy_pass https://" not in configuration
    assert "proxy_set_header Authorization $http_authorization;" in configuration
    assert "proxy_set_header X-MS-CLIENT-PRINCIPAL '';" in configuration
    assert "proxy_set_header X-Meghkosha-User-Token '';" in configuration
    assert "proxy_intercept_errors off;" in configuration
    assert "proxy_pass_header WWW-Authenticate;" in configuration
    assert "same-origin-allow-popups" in configuration
    assert "frame-src 'self' https://login.microsoftonline.com" in configuration
    assert "$http_authorization" not in configuration.splitlines()[0]
    assert "$request_uri" not in configuration.splitlines()[0]
    assert 'NGINX_ENVSUBST_FILTER="^API_HOST$"' in (PROJECT_ROOT / "web" / "Dockerfile").read_text()


def test_container_smoke_is_portable_and_uses_only_synthetic_identity():
    script = PROJECT_ROOT / "scripts" / "tests" / "container-smoke.py"
    result = subprocess.run([sys.executable, str(script), "--help"], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert "--api" in result.stdout and "--web" in result.stdout
    source = script.read_text()
    assert '"proxiedApi": "passed"' in source
    assert '"proxiedForgedIdentity": "rejected"' in source
    assert "unavailableHttpsUpstream" not in source
    task = (script.parent / "acr-smoke.yaml").read_text()
    assert task.count("API_HOST=phase2-api:8000") == 2
    assert "disableWorkingDirectoryOverride: true" in task
    assert "/usr/bin/python /workspace/container-smoke.py" in task
    assert "nginx -t" in task
    assert "MEGHKOSHA_AI_ENABLED=false" in task
    assert "ignoreErrors" not in task
    assert task.count("docker image save --output") == 2
    assert task.count("--severity HIGH,CRITICAL --exit-code 1") == 2
    assert "--ignore-unfixed" not in task
    assert "aquasec/trivy:0.74.0@sha256:" in task
    assert task.count("when: [export-web-image]") == 2
    assert task.count("--format json --quiet") == 2
    assert "--cache-dir /workspace/trivy-api-cache" in task
    assert "--cache-dir /workspace/trivy-web-cache" in task
    assert "616dc9b8-b4aa-415f-8dcb-71bc462916c5" not in task


def test_runtime_test_image_keeps_production_dependencies_and_identity_isolated():
    recipe = (PROJECT_ROOT / "scripts" / "tests" / "runtime-tests.Dockerfile").read_text()
    runtime = recipe.split("FROM ${API_IMAGE}", 1)[1]
    assert "PYTHONPATH=/opt/python:/opt/test-packages:/app" in runtime
    assert "USER 65532:65532" in runtime
    assert "MEGHKOSHA_AI_ENABLED=false" in runtime
    assert "RUN " not in runtime
    assert "COPY --chown=65532:65532 tests /app/tests" in runtime
    command = json.loads(next(line.removeprefix("CMD ") for line in runtime.splitlines() if line.startswith("CMD ")))
    assert command[:3] == ["/usr/bin/python", "-m", "pytest"]
    assert "--ignore=tests/test_packaging.py" in command
    assert "--disable-socket" not in command
    assert "616dc9b8-b4aa-415f-8dcb-71bc462916c5" not in recipe


def run_input_validation(overrides=None, operation="Local"):
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell 7.4 or later is required for deployment-input checks")
    environment = {name: value for name, value in os.environ.items()
                   if not name.startswith(("AZURE_", "APP_", "SERVICE_", "MEGHKOSHA_", "FOUNDRY_"))}
    environment.update(AZURE_ENV_NAME="app-local-validation")
    environment.update(overrides or {})
    return subprocess.run(
        [shell, "-NoProfile", "-NonInteractive", "-File", str(PROJECT_ROOT / "scripts" / "validate-deployment-inputs.ps1"),
         "-Operation", operation], env=environment, capture_output=True, text=True, timeout=20,
    )


@pytest.mark.parametrize("profile", ["core", "data", "ai"])
def test_each_profile_defaults_to_no_processor_ai_runtime_or_export_exception(profile):
    result = run_input_validation({"APP_PROFILE": profile})
    assert result.returncode == 0, result.stderr
    settings = json.loads(result.stdout)
    assert settings["profile"] == profile
    assert settings["hosting"] == "aks"
    assert settings["tlsIssuer"] == "letsencrypt"
    assert not settings["signInConfigured"]
    assert not settings["processorEnabled"]
    assert not settings["aiRuntimeEnabled"]
    assert not settings["chatRuntimeEnabled"]
    assert not settings["nativeExportNetworkException"]
    assert settings["cloudPreflightStillRequired"]


@pytest.mark.parametrize("operation", ["Provision", "Publish", "Deploy", "Down"])
def test_azure_operations_are_blocked_without_explicit_approval(operation):
    result = run_input_validation(operation=operation)
    assert result.returncode != 0
    assert "Azure changes are not approved" in result.stderr


@pytest.mark.parametrize("overrides, message", [
    ({"APP_PROFILE": "unknown"}, "APP_PROFILE must be"),
    ({"APP_PROVISIONED_PROFILE": "ai", "APP_PROFILE": "core"}, "Profile downgrade"),
    ({"APP_AKS_SUBNET_PREFIX": "10.42.1.0/27"}, "must not overlap"),
    ({"APP_PRIVATE_ENDPOINT_SUBNET_PREFIX": "10.43.0.0/27"}, "within the VNet"),
    ({"APP_AKS_SERVICE_CIDR": "10.42.0.0/16"}, "APP_AKS_SERVICE_CIDR must not overlap the VNet"),
    ({"APP_AKS_POD_CIDR": "10.0.0.0/16"}, "must not overlap"),
    ({"APP_AKS_ZONES": "1,4"}, "APP_AKS_ZONES must be"),
    ({"APP_AKS_SKU_TIER": "Basic"}, "APP_AKS_SKU_TIER must be"),
    ({"APP_AKS_USER_VM_SIZE": "Standard_D4s_v5"}, "local temp disk"),
    ({"APP_TLS_CLUSTER_ISSUER": "self-signed"}, "APP_TLS_CLUSTER_ISSUER must be"),
    ({"APP_INGRESS_DNS_LABEL": "9lives"}, "APP_INGRESS_DNS_LABEL must be"),
    ({"APP_CUSTOM_DOMAIN": "not a domain"}, "APP_CUSTOM_DOMAIN must be"),
    ({"APP_ACME_EMAIL": "ops"}, "APP_ACME_EMAIL must be"),
    ({"APP_AKS_OUTBOUND_PORTS": "6404"}, "APP_AKS_OUTBOUND_PORTS must be a multiple of 8"),
    ({"APP_AKS_OUTBOUND_PORTS": "512"}, "APP_AKS_OUTBOUND_PORTS must be a whole number between 1024 and 64000"),
    ({"APP_AKS_OUTBOUND_IPS": "0"}, "APP_AKS_OUTBOUND_IPS must be a whole number"),
    ({"APP_AKS_OUTBOUND_IDLE_TIMEOUT": "2"}, "APP_AKS_OUTBOUND_IDLE_TIMEOUT must be a whole number between 4 and 120"),
    ({"APP_AKS_USER_MAX_NODES": "6"}, "need 70400 SNAT ports"),
    ({"APP_AKS_USER_MAX_NODES": "five"}, "APP_AKS_USER_MAX_NODES must be a whole number"),
    ({"APP_ENABLE_PROCESSOR": "True"}, "must be true or false (lowercase)"),
    ({"MEGHKOSHA_API_CLIENT_ID": "33333333-3333-3333-3333-333333333333"}, "must contain a nonzero UUID"),
    ({"APP_EXPORT_TRUSTED_SERVICES": "true"}, "not part of the core stage"),
    ({"APP_ENABLE_PROCESSOR": "true"}, "requires the data"),
    ({"APP_ENABLE_AI_RUNTIME": "true"}, "AI runtime requires"),
    ({"APP_ENABLE_CHAT_RUNTIME": "true"}, "Foundry chat requires"),
    ({"APP_MODEL_DEPLOYMENTS": "{}"}, "must be a JSON array"),
    ({"APP_PROFILE": "ai", "APP_MODEL_DEPLOYMENTS": '[{"name":"test"}]'}, "missing modelFormat"),
])
def test_invalid_or_unimplemented_configuration_fails_before_cloud_calls(overrides, message):
    result = run_input_validation(overrides)
    assert result.returncode != 0
    assert message in result.stderr


def test_a_second_outbound_ip_makes_room_for_a_larger_application_pool():
    result = run_input_validation({"APP_AKS_USER_MAX_NODES": "6", "APP_AKS_OUTBOUND_IPS": "2"})
    assert result.returncode == 0, result.stderr


def test_approved_model_router_enables_chat_without_hosted_agent_narration():
    result = run_input_validation({
        "APP_PROFILE": "ai",
        "APP_MODEL_DEPLOYMENTS": json.dumps([{
            "name": "model-router",
            "modelFormat": "OpenAI",
            "modelName": "model-router",
            "modelVersion": "2025-11-18",
            "sku": "GlobalStandard",
            "capacity": 20,
        }]),
        "APP_ENABLE_CHAT_RUNTIME": "true",
        "APP_AI_VALIDATED": "true",
        "MODEL_ROUTER_DEPLOYMENT_NAME": "model-router",
    })

    assert result.returncode == 0, result.stderr
    settings = json.loads(result.stdout)
    assert settings["chatRuntimeEnabled"] is True
    assert settings["aiRuntimeEnabled"] is False


def test_publish_and_deploy_require_the_provisioned_registry_and_cluster():
    approved = {"APP_ALLOW_AZURE_CHANGES": "true"}
    result = run_input_validation({**approved, "AZURE_CONTAINER_REGISTRY_ENDPOINT": "testapp.azurecr.io"}, "Publish")
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout)["operation"] == "Publish"
    result = run_input_validation(approved, "Publish")
    assert result.returncode != 0 and "provisioned environment registry" in result.stderr
    result = run_input_validation(approved, "Deploy")
    assert result.returncode != 0 and "provisioned AKS cluster" in result.stderr
    result = run_input_validation({**approved, "AZURE_AKS_CLUSTER_NAME": "aks-0123456789abc"}, "Deploy")
    assert result.returncode == 0, result.stderr


def test_ai_deployment_helper_plans_the_recommended_aks_profile_without_sign_in_steps():
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell 7.4 or later is required for deployment-helper checks")
    script = PROJECT_ROOT / "scripts" / "deploy-ai.ps1"
    result = subprocess.run(
        [shell, "-NoProfile", "-NonInteractive", "-File", str(script),
         "-EnvironmentName", "fresh-ai", "-Location", "centralindia", "-PlanOnly"],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["environment"] == "fresh-ai"
    assert plan["hosting"] == "aks"
    assert plan["preview"] is True
    assert plan["enableProcessor"] is True
    assert plan["bootstrapIdentity"] is False
    assert plan["roleAssignments"] is False
    assert plan["maxAttempts"] == 3
    assert plan["settings"] == {
        "AZURE_LOCATION": "centralindia",
        "APP_PROFILE": "ai",
        "APP_EXPORT_TRUSTED_SERVICES": "true",
        "APP_MODEL_DEPLOYMENTS": '[{"name":"model-router","modelFormat":"OpenAI","modelName":"model-router","modelVersion":"2025-11-18","sku":"GlobalStandard","capacity":20}]',
        "MODEL_ROUTER_DEPLOYMENT_NAME": "model-router",
        "APP_ENABLE_CHAT_RUNTIME": "true",
        "APP_AI_VALIDATED": "true",
        "APP_ENABLE_AI_RUNTIME": "false",
        "APP_ENABLE_PROCESSOR": "true",
    }
    source = script.read_text(encoding="utf-8")
    assert "deploy-end-to-end.ps1" in source
    assert "SkipIdentityBootstrap = $true" in source and "SkipRoleAssignments = $true" in source
    assert "azd down" not in source and "--purge" not in source


def test_ai_deployment_helper_plan_supports_explicit_opt_outs():
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell 7.4 or later is required for deployment-helper checks")
    result = subprocess.run(
        [shell, "-NoProfile", "-NonInteractive", "-File", str(PROJECT_ROOT / "scripts" / "deploy-ai.ps1"),
         "-EnvironmentName", "fresh-ai", "-SkipPreview", "-SkipProcessor", "-MaxAttempts", "5", "-PlanOnly"],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, result.stderr
    plan = json.loads(result.stdout)
    assert plan["preview"] is False
    assert plan["enableProcessor"] is False
    assert "APP_ENABLE_PROCESSOR" not in plan["settings"]
    assert plan["maxAttempts"] == 5


def test_ai_deployment_helper_environment_inventory_handles_empty_list():
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell 7.4 or later is required for deployment-helper checks")
    expression = """
Set-StrictMode -Version Latest
$EnvironmentName = 'fresh-ai'
function Test-Inventory([string] $Json) {
    $environments = @($Json | ConvertFrom-Json)
    @($environments | Where-Object {
        $_ -ne $null -and $_.PSObject.Properties['Name'] -ne $null -and $_.Name -eq $EnvironmentName
    }).Count -gt 0
}
@{
    empty = Test-Inventory '[]'
    present = Test-Inventory '[{"Name":"fresh-ai"}]'
    other = Test-Inventory '[{"Name":"other"}]'
} | ConvertTo-Json -Compress
"""
    result = subprocess.run(
        [shell, "-NoProfile", "-NonInteractive", "-Command", expression],
        capture_output=True, text=True, timeout=20,
    )
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"empty": False, "present": True, "other": False}


def run_powershell_harness(name, timeout=180):
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell 7.4 or later is required for the deployment harnesses")
    result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File", str(PROJECT_ROOT / "scripts" / "tests" / name)],
                            capture_output=True, text=True, timeout=timeout)
    assert result.returncode == 0, result.stdout[-4000:] + result.stderr
    return json.loads(result.stdout.strip().splitlines()[-1])


def test_end_to_end_helper_deploys_once_retries_and_never_hides_a_question():
    summary = run_powershell_harness("test-deploy-end-to-end.ps1")
    assert summary["result"] == "passed"
    assert summary["rerunRedeploysOnce"] and summary["noHiddenPrompts"] and summary["azdQuestionsAskedInTerminal"]
    assert summary["serviceTreeIdAskedAndRemembered"] and summary["kubernetesToolsOfferedAndInstalled"]
    assert summary["kubernetesToolsPathExplained"]


def test_aks_bootstrap_hook_waits_for_rbac_and_installs_only_the_pinned_cert_manager():
    summary = run_powershell_harness("test-aks-bootstrap.ps1")
    assert summary == {"result": "passed", "rbacWaited": True, "checksumEnforced": True,
                       "webhookRetried": True, "kubeconfigIsolated": True,
                       "kubectlWarningsIgnored": True, "deniedAccessReported": True}


@pytest.mark.parametrize("apply", [False, True])
def test_identity_bootstrap_is_offline_by_default_and_requires_explicit_apply_approval(apply):
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell is required for the bootstrap contract")
    environment = dict(os.environ, APP_ALLOW_AZURE_CHANGES="false")
    tenant = "11111111-1111-1111-1111-111111111111"
    subscription = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    command = [shell, "-NoProfile", "-NonInteractive", "-File", str(PROJECT_ROOT / "scripts" / "bootstrap-identity.ps1"),
               "-TenantId", tenant, "-SubscriptionId", subscription, "-EnvironmentName", "app-test",
               "-WebOrigin", "https://app.example.test",
               "-OboManagedIdentityResourceId", f"/subscriptions/{subscription}/resourceGroups/rg-app/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-obo"]
    if apply:
        command.append("-Apply")
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=20)
    if apply:
        assert result.returncode != 0
        assert "Identity changes are not approved" in result.stderr
    else:
        assert result.returncode == 0, result.stderr
        plan = json.loads(result.stdout)
        assert plan["action"] == "Preview"
        assert plan["createsClientSecret"] is False
        assert plan["assignsSubscriptionRoles"] is False
        assert plan["administratorConsentRequested"] is False
        assert plan["callbacks"] == ["https://app.example.test/auth-callback.html"]


def test_identity_bootstrap_apply_is_idempotent_against_offline_graph_transport():
    shell = shutil.which("pwsh")
    if not shell:
        pytest.skip("PowerShell is required for the bootstrap contract")
    result = subprocess.run([shell, "-NoProfile", "-NonInteractive", "-File",
                             str(PROJECT_ROOT / "scripts" / "tests" / "test-bootstrap.ps1")],
                            capture_output=True, text=True, timeout=30)
    assert result.returncode == 0, result.stderr
    summary = json.loads(result.stdout)
    assert summary["networkCalls"] == 0
    assert summary["idempotentCreates"]
    assert summary["rejectedConflictsBeforeWrites"] == 4
    assert summary["consentFailureRecoverable"]


# ---------------------------------------------------------------------------
# Terraform (infra/) - offline: `terraform test` runs against mocked providers.
# ---------------------------------------------------------------------------

def _terraform_environment(data_dir):
    environment = {name: value for name, value in os.environ.items() if not name.startswith(("ARM_", "TF_VAR_"))}
    environment.update(
        TF_IN_AUTOMATION="1",
        TF_INPUT="0",
        TF_DATA_DIR=str(data_dir),
        TF_PLUGIN_CACHE_DIR=os.environ.get("TF_PLUGIN_CACHE_DIR", str(Path(tempfile.gettempdir()) / "cloudlens-terraform-plugin-cache")),
        CHECKPOINT_DISABLE="1",
    )
    Path(environment["TF_PLUGIN_CACHE_DIR"]).mkdir(parents=True, exist_ok=True)
    return environment


@pytest.fixture(scope="module")
def terraform_roots(tmp_path_factory):
    """Initializes a scratch copy of each Terraform root, so tests never touch infra/ or its lock files."""
    terraform = shutil.which("terraform")
    if not terraform:
        pytest.skip("Terraform 1.11 or later is required for the infrastructure contract tests")
    roots = {}
    for root in TERRAFORM_ROOTS:
        workspace = tmp_path_factory.mktemp(root.replace("/", "-"))
        copy = workspace / "module"
        shutil.copytree(PROJECT_ROOT / root, copy, ignore=shutil.ignore_patterns(".terraform", "*.tfstate*", "export-access", "model-router", "k8s"))
        environment = _terraform_environment(workspace / "data")
        result = subprocess.run([terraform, f"-chdir={copy}", "init", "-backend=false", "-no-color"],
                                env=environment, capture_output=True, text=True, timeout=600)
        if result.returncode != 0 and re.search(r"Failed to query available provider packages|could not connect|no such host|timeout", result.stdout + result.stderr):
            pytest.skip("Terraform providers could not be downloaded; run once with network access to fill the plugin cache")
        assert result.returncode == 0, result.stdout + result.stderr
        roots[root] = (copy, environment)
    return terraform, roots


@pytest.mark.parametrize("root", TERRAFORM_ROOTS)
def test_terraform_root_is_formatted_and_valid(terraform_roots, root):
    terraform, roots = terraform_roots
    copy, environment = roots[root]
    formatted = subprocess.run([terraform, "fmt", "-check", "-recursive", "-diff", "-no-color", str(PROJECT_ROOT / root)],
                               env=environment, capture_output=True, text=True, timeout=60)
    assert formatted.returncode == 0, formatted.stdout + formatted.stderr
    validated = subprocess.run([terraform, f"-chdir={copy}", "validate", "-no-color"],
                               env=environment, capture_output=True, text=True, timeout=180)
    assert validated.returncode == 0, validated.stdout + validated.stderr
    assert "Warning" not in validated.stdout + validated.stderr


@pytest.mark.parametrize("root", TERRAFORM_ROOTS)
def test_terraform_contract_tests_pass_against_mocked_providers(terraform_roots, root):
    terraform, roots = terraform_roots
    copy, environment = roots[root]
    result = subprocess.run([terraform, f"-chdir={copy}", "test", "-no-color"],
                            env=environment, capture_output=True, text=True, timeout=900)
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr
    assert re.search(r"Success! \d+ passed, 0 failed\.", result.stdout), result.stdout[-2000:]


def _terraform_variables():
    source = (PROJECT_ROOT / "infra" / "variables.tf").read_text()
    return re.findall(r'^variable "([a-z0-9_]+)"', source, re.MULTILINE)


def _terraform_outputs():
    source = (PROJECT_ROOT / "infra" / "outputs.tf").read_text()
    return set(re.findall(r'^output "([A-Z0-9_]+)"', source, re.MULTILINE))


def _azd_substitute(template, values):
    # The subset of drone/envsubst that main.tfvars.json uses: ${NAME} and ${NAME=default} (default when empty).
    def replace(match):
        value = values.get(match.group(1), "")
        return value if value else (match.group(3) or "")
    return re.sub(r"\$\{([A-Z0-9_]+)(=([^}]*))?\}", replace, template)


def test_azd_parameter_file_maps_every_terraform_variable_from_the_environment():
    template = (PROJECT_ROOT / "infra" / "main.tfvars.json").read_text()
    variables = _terraform_variables()
    defaults = json.loads(_azd_substitute(template, {"AZURE_ENV_NAME": "dev"}))
    assert sorted(defaults) == sorted(variables)
    assert defaults["environment_name"] == "dev"
    assert defaults["profile"] == "core" and defaults["provisioned_profile"] == ""
    assert defaults["model_deployments"] == []
    assert defaults["enable_processor"] == "false" and defaults["allow_native_export_trusted_services"] == "false"
    assert defaults["processor_schedule"] == "*/5 * * * *"
    assert defaults["aks_zones"] == "1,2,3" and defaults["aks_sku_tier"] == "Standard"
    assert defaults["aks_system_vm_size"] == "Standard_D2ds_v5" and defaults["aks_user_vm_size"] == "Standard_D4ds_v5"
    assert defaults["tls_cluster_issuer"] == "letsencrypt"
    assert '"principal_id": "${AZURE_PRINCIPAL_ID}"' in template
    for name in ("daily_export_retention_days", "closed_month_retention_days", "export_parallel_months", "log_retention_days",
                 "aks_system_min_nodes", "aks_system_max_nodes", "aks_user_min_nodes", "aks_user_max_nodes",
                 "aks_outbound_ip_count", "aks_outbound_ports_per_node", "aks_outbound_idle_timeout_minutes"):
        assert defaults[name].isdigit(), name
    assert (defaults["aks_outbound_ip_count"], defaults["aks_outbound_ports_per_node"], defaults["aks_outbound_idle_timeout_minutes"]) == ("1", "6400", "4")
    router = '[{"name":"model-router","modelFormat":"OpenAI","modelName":"model-router","modelVersion":"2025-11-18","sku":"GlobalStandard","capacity":20}]'
    configured = json.loads(_azd_substitute(template, {"AZURE_ENV_NAME": "dev", "APP_PROFILE": "ai", "APP_MODEL_DEPLOYMENTS": router,
                                                       "APP_AKS_ZONES": "none", "AZURE_RESOURCE_GROUP": "rg-dev"}))
    assert configured["model_deployments"][0]["capacity"] == 20
    assert configured["aks_zones"] == "none" and configured["resource_group_name"] == "rg-dev"


AZD_PARAMETERS_TEST = """
mock_provider "azurerm" {
  mock_data "azurerm_client_config" {
    defaults = {
      tenant_id       = "11111111-1111-1111-1111-111111111111"
      subscription_id = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      object_id       = "22222222-2222-2222-2222-222222222222"
      client_id       = "33333333-3333-3333-3333-333333333333"
    }
  }
}

mock_provider "time" {}

run "azd_strings_convert_to_the_declared_types" {
  command = plan

  assert {
    condition = (
      var.enable_processor == true && var.allow_native_export_trusted_services == true &&
      var.enable_chat_runtime == true && var.enable_ai_runtime == false &&
      var.daily_export_retention_days == 60 && var.closed_month_retention_days == 214 &&
      var.aks_user_min_nodes == 2 && var.model_deployments[0].capacity == 20 &&
      var.principal_id == "99999999-9999-9999-9999-999999999999" && var.resource_group_name == "rg-dev"
    )
    error_message = "azd's substituted strings did not convert to the declared variable types."
  }

  assert {
    condition = (
      output.APP_PROFILE == "ai" && output.APP_PROVISIONED_PROFILE == "ai" &&
      output.FOUNDRY_CHAT_ENABLED == "true" && output.MEGHKOSHA_AI_ENABLED == "false" &&
      output.APP_PROCESSOR_DEPLOYED == "true" && output.APP_PROCESSOR_CRON == "*/5 * * * *" &&
      output.AZURE_AKS_NAMESPACE == "cloudlens" && output.APP_TLS_CLUSTER_ISSUER == "letsencrypt"
    )
    error_message = "The recommended settings must produce the outputs the manifests read."
  }
}
"""


def test_terraform_accepts_the_recommended_settings_exactly_as_azd_substitutes_them(terraform_roots, tmp_path):
    terraform, roots = terraform_roots
    copy, environment = roots["infra"]
    router = '[{"name":"model-router","modelFormat":"OpenAI","modelName":"model-router","modelVersion":"2025-11-18","sku":"GlobalStandard","capacity":20}]'
    settings = {
        "AZURE_ENV_NAME": "dev", "AZURE_LOCATION": "centralindia", "AZURE_RESOURCE_GROUP": "rg-dev",
        "AZURE_PRINCIPAL_ID": "99999999-9999-9999-9999-999999999999", "APP_PROFILE": "ai", "APP_PROVISIONED_PROFILE": "ai",
        "APP_EXPORT_TRUSTED_SERVICES": "true", "APP_MODEL_DEPLOYMENTS": router, "MODEL_ROUTER_DEPLOYMENT_NAME": "model-router",
        "APP_ENABLE_CHAT_RUNTIME": "true", "APP_AI_VALIDATED": "true", "APP_ENABLE_AI_RUNTIME": "false", "APP_ENABLE_PROCESSOR": "true",
    }
    parameters = tmp_path / "main.tfvars.json"
    parameters.write_text(_azd_substitute((PROJECT_ROOT / "infra" / "main.tfvars.json").read_text(), settings))
    tests = copy / "azd-tests"
    tests.mkdir(exist_ok=True)
    (tests / "azd_parameters.tftest.hcl").write_text(AZD_PARAMETERS_TEST)
    result = subprocess.run([terraform, f"-chdir={copy}", "test", "-no-color", "-test-directory=azd-tests", f"-var-file={parameters}"],
                            env=environment, capture_output=True, text=True, timeout=600)
    assert result.returncode == 0, result.stdout[-6000:] + result.stderr
    assert "Success! 1 passed, 0 failed." in result.stdout


MANIFESTS = {
    "api": PROJECT_ROOT / "api" / "manifests" / "api.tmpl.yaml",
    "processor": PROJECT_ROOT / "api" / "manifests" / "processor.tmpl.yaml",
    "web": PROJECT_ROOT / "web" / "manifests" / "web.tmpl.yaml",
}
SAFE_TEMPLATE_ACTIONS = (
    r'\{\{ index \.Env "[A-Z0-9_]+" \| printf "%q" \}\}',
    r'\{\{ or \(index \.Env "[A-Z0-9_]+"\) "[^"{}]+" \| printf "%q" \}\}',
    r'\{\{ if eq \(index \.Env "[A-Z0-9_]+"\) "true" \}\}false\{\{ else \}\}true\{\{ end \}\}',
)


def test_manifest_templates_use_only_quoted_lookups_that_cannot_render_no_value():
    for name, path in MANIFESTS.items():
        text = path.read_text()
        remainder = text
        for pattern in SAFE_TEMPLATE_ACTIONS:
            remainder = re.sub(pattern, "", remainder)
        assert "{{" not in remainder and "}}" not in remainder, f"{name}: unsupported template action"
        assert ".Env." not in text, f"{name}: .Env.NAME renders <no value> when unset; use index"
    for path in (PROJECT_ROOT / "api" / "manifests").glob("*.yaml"):
        if not path.name.endswith(".tmpl.yaml"):
            assert "{{" not in path.read_text(), f"{path.name} is applied verbatim, so it cannot use templates"


def test_every_value_read_by_the_manifests_and_hook_is_provided():
    produced_by_azd = {"SERVICE_API_IMAGE_NAME", "SERVICE_WEB_IMAGE_NAME", "AZURE_SUBSCRIPTION_ID"}
    set_by_operator = {"MEGHKOSHA_API_CLIENT_ID", "MEGHKOSHA_WEB_CLIENT_ID", "APP_ACME_EMAIL"}
    outputs = _terraform_outputs()
    read = set()
    for path in MANIFESTS.values():
        for action in re.findall(r"\{\{.*?\}\}", path.read_text()):
            read |= set(re.findall(r'index \.Env "([A-Z0-9_]+)"', action))
    read |= set(re.findall(r"\$\{([A-Z0-9_]+)\}", (PROJECT_ROOT / "infra" / "k8s" / "cluster-bootstrap.yaml").read_text()))
    read |= set(re.findall(r"Get-Setting '([A-Z0-9_]+)'", (PROJECT_ROOT / "scripts" / "aks-bootstrap.ps1").read_text()))
    missing = read - outputs - produced_by_azd - set_by_operator
    assert not missing, f"Values nothing provides: {sorted(missing)}"
    deploy_script = (PROJECT_ROOT / "scripts" / "deploy-end-to-end.ps1").read_text()
    for name in set(re.findall(r"Get-AzdValue '([A-Z0-9_]+)'", deploy_script)) - produced_by_azd - set_by_operator:
        assert name in outputs or name in {"AZURE_ENV_NAME", "APP_SERVICE_MANAGEMENT_REFERENCE"}, name


def _container_environment(text):
    return re.findall(r"- name: ([A-Z0-9_]+)\n\s+value:", text)


def test_api_and_processor_receive_the_same_settings_as_the_container_apps_did():
    api = _container_environment(MANIFESTS["api"].read_text())
    assert sorted(api) == sorted([
        "AZURE_CLIENT_ID", "AZURE_TENANT_ID", "MEGHKOSHA_API_CLIENT_ID", "MEGHKOSHA_WEB_CLIENT_ID",
        "MEGHKOSHA_OBO_MANAGED_IDENTITY_CLIENT_ID", "MEGHKOSHA_ACTION_WRITES_PAUSED", "APP_PROFILE", "APP_SCHEDULER_ENABLED",
        "MEGHKOSHA_AI_ENABLED", "FOUNDRY_CHAT_ENABLED", "AI_PROJECT_ENDPOINT", "AI_SERVICES_ENDPOINT", "AGENT_NAME",
        "MODEL_ROUTER_DEPLOYMENT_NAME", "COST_EXPORT_STORAGE_URL", "COST_EXPORT_STORAGE_RESOURCE_ID", "COST_EXPORT_CONTAINER",
        "REPORT_SNAPSHOT_CONTAINER", "CONTROL_STATE_CONTAINER", "COST_EXPORT_NAME", "COST_EXPORT_DAILY_NAME",
        "FOCUS_EXPORT_PARALLEL_MONTHS", "COST_EXPORT_LOCATION", "REPORT_PUBLIC_APP_URL",
    ])
    processor = _container_environment(MANIFESTS["processor"].read_text())
    assert sorted(processor) == sorted([
        "AZURE_CLIENT_ID", "AZURE_TENANT_ID", "APP_SCHEDULER_ENABLED", "COST_EXPORT_STORAGE_URL", "COST_EXPORT_STORAGE_RESOURCE_ID",
        "COST_EXPORT_NAME", "COST_EXPORT_DAILY_NAME", "FOCUS_EXPORT_PARALLEL_MONTHS", "COST_EXPORT_CONTAINER",
        "CONTROL_STATE_CONTAINER", "MEGHKOSHA_AI_ENABLED",
    ])
    assert 'name: MEGHKOSHA_ACTION_WRITES_PAUSED\n              value: "true"' in MANIFESTS["api"].read_text()
    assert 'name: AZURE_CLIENT_ID\n                  value: {{ index .Env "AZURE_PROCESSOR_IDENTITY_CLIENT_ID"' in MANIFESTS["processor"].read_text()


def test_workloads_run_hardened_with_workload_identity_instead_of_secrets():
    for name, path in MANIFESTS.items():
        text = path.read_text()
        assert text.count("runAsNonRoot: true") == 1, name
        assert text.count("type: RuntimeDefault") == 1, name
        assert text.count("allowPrivilegeEscalation: false") == 1, name
        assert text.count("readOnlyRootFilesystem: true") == 1, name
        assert "- ALL" in text, name
        assert "automountServiceAccountToken: false" in text, name
        assert "privileged: true" not in text and "hostNetwork" not in text and "hostPath" not in text, name
        assert "secretKeyRef" not in text and "kind: Secret" not in text, name
    api, processor, web = (MANIFESTS[key].read_text() for key in ("api", "processor", "web"))
    for text, service_account, identity in ((api, "api", "AZURE_API_IDENTITY_CLIENT_ID"),
                                            (processor, "processor", "AZURE_PROCESSOR_IDENTITY_CLIENT_ID")):
        assert f"serviceAccountName: {service_account}" in text
        assert f'azure.workload.identity/client-id: {{{{ index .Env "{identity}" | printf "%q" }}}}' in text
        assert 'azure.workload.identity/use: "true"' in text
    assert "azure.workload.identity" not in web
    assert "runAsUser: 65532" in api and "runAsUser: 65532" in processor and "runAsUser: 101" in web
    for text, path in ((api, "/api/health"), (web, "/healthz")):
        assert text.count(f"path: {path}") == 3
        assert "kind: PodDisruptionBudget" in text and "maxUnavailable: 1" in text
        assert "kind: HorizontalPodAutoscaler" in text and "minReplicas: 2" in text
        assert "\n  replicas:" not in text, "the HPA owns the replica count"
    assert 'value: "api:8000"' in web
    for mount in ("mountPath: /tmp", "mountPath: /etc/nginx/conf.d", "mountPath: /var/cache/nginx"):
        assert mount in web


def _spread_constraints(text):
    """Each topology spread constraint of the manifest's Deployment, keyed by its topology key."""
    block = text.split("topologySpreadConstraints:", 1)[1].split("containers:", 1)[0]
    constraints = {}
    for entry in block.split("- maxSkew: 1")[1:]:
        key = re.search(r"topologyKey: (\S+)", entry).group(1)
        constraints[key] = entry
    return constraints


def test_api_and_web_replicas_are_spread_across_nodes_without_blocking_rollouts():
    for name in ("api", "web"):
        constraints = _spread_constraints(MANIFESTS[name].read_text())
        assert set(constraints) == {"topology.kubernetes.io/zone", "kubernetes.io/hostname"}, name
        hostname, zone = constraints["kubernetes.io/hostname"], constraints["topology.kubernetes.io/zone"]
        # Hard across nodes, so one node failure never takes every replica down; soft across zones,
        # because a zoneless region or a single surviving zone must not leave pods pending.
        assert "whenUnsatisfiable: DoNotSchedule" in hostname, name
        assert "whenUnsatisfiable: ScheduleAnyway" in zone, name
        for entry in (hostname, zone):
            # Without Honor the tainted system nodes count as empty nodes, so a third replica could never be placed.
            assert "nodeTaintsPolicy: Honor" in entry, name
            # Without it a rollout's new pods could all land on one node while the old ones drain.
            assert "matchLabelKeys:\n            - pod-template-hash" in entry, name
            assert f"app.kubernetes.io/name: {name}" in entry, name


def test_processor_cronjob_mirrors_the_container_apps_job_and_never_overlaps():
    text = MANIFESTS["processor"].read_text()
    assert 'schedule: {{ or (index .Env "APP_PROCESSOR_CRON") "*/5 * * * *" | printf "%q" }}' in text
    assert "timeZone: Etc/UTC" in text
    assert "concurrencyPolicy: Forbid" in text
    assert 'suspend: {{ if eq (index .Env "APP_PROCESSOR_DEPLOYED") "true" }}false{{ else }}true{{ end }}' in text
    assert "backoffLimit: 0" in text and "activeDeadlineSeconds: 3600" in text and "restartPolicy: Never" in text
    assert "- jobs.scheduler" in text and "- /usr/bin/python" in text
    assert 'image: {{ index .Env "SERVICE_API_IMAGE_NAME" | printf "%q" }}' in text
    assert 'cpu: "1"' in text and "memory: 2Gi" in text


def test_only_the_web_pods_reach_the_api_and_tls_comes_from_cert_manager():
    policies = (PROJECT_ROOT / "api" / "manifests" / "10-network-policies.yaml").read_text()
    assert "name: default-deny-ingress" in policies and "podSelector: {}" in policies
    assert "name: api-from-web" in policies and "port: 8000" in policies
    assert "acme.cert-manager.io/http01-solver" in policies and "port: 8089" in policies
    assert policies.count("kubernetes.io/metadata.name: app-routing-system") == 1
    namespace = (PROJECT_ROOT / "api" / "manifests" / "00-namespace.yaml").read_text()
    assert "name: cloudlens" in namespace and "pod-security.kubernetes.io/enforce: baseline" in namespace
    assert "pod-security.kubernetes.io/warn: restricted" in namespace
    web = MANIFESTS["web"].read_text()
    assert "kind: Ingress" in web and "secretName: web-tls" in web
    assert 'cert-manager.io/cluster-issuer: {{ index .Env "APP_TLS_CLUSTER_ISSUER" | printf "%q" }}' in web
    assert 'ingressClassName: {{ index .Env "APP_INGRESS_CLASS" | printf "%q" }}' in web
    assert web.count('{{ index .Env "APP_INGRESS_HOST" | printf "%q" }}') == 2
    assert "name: web-from-ingress" in web and "port: 8080" in web
    assert "type: LoadBalancer" not in web + MANIFESTS["api"].read_text(), "only the ingress controller is exposed"
    bootstrap = (PROJECT_ROOT / "infra" / "k8s" / "cluster-bootstrap.yaml").read_text()
    assert "kind: NginxIngressController" in bootstrap
    assert 'service.beta.kubernetes.io/azure-pip-name: "${APP_INGRESS_PUBLIC_IP_NAME}"' in bootstrap
    assert bootstrap.count("kind: ClusterIssuer") == 2 and bootstrap.count("http01:") == 2
    hook = (PROJECT_ROOT / "scripts" / "aks-bootstrap.ps1").read_text()
    assert re.search(r"\$CertManagerVersion = 'v\d+\.\d+\.\d+'", hook)
    assert re.search(r"\$CertManagerSha256 = '[a-f0-9]{64}'", hook)
    assert "Get-FileHash" in hook and "--server-side" in hook


def test_azure_yaml_deploys_both_services_to_the_terraform_provisioned_cluster():
    text = (PROJECT_ROOT / "azure.yaml").read_text()
    assert re.search(r"infra:\n  provider: terraform\n  path: infra\n  module: main", text)
    assert text.count("host: aks") == 2
    assert text.count("namespace: cloudlens") == 2
    assert text.count("remoteBuild: true") == 2 and text.count("platform: linux/amd64") == 2
    assert text.count("deploymentPath: manifests") == 2
    assert "containerapp" not in text and "resourceName" not in text
    assert re.search(r"postprovision:\n    shell: pwsh\n    run: \./scripts/aks-bootstrap\.ps1\n    interactive: true\n", text)
    assert 'namespace         = "cloudlens"' in (PROJECT_ROOT / "infra" / "main.tf").read_text()
    assert text.index("  api:") < text.index("  web:")


def test_no_container_apps_or_bicep_artifacts_remain():
    assert not list((PROJECT_ROOT / "infra").rglob("*.bicep*")) and not (PROJECT_ROOT / "infra" / "main.json").exists()
    for path in [PROJECT_ROOT / "azure.yaml", *(PROJECT_ROOT / "scripts").glob("*.ps1"), *(PROJECT_ROOT / "infra").rglob("*.tf")]:
        text = path.read_text(encoding="utf-8")
        assert "az containerapp" not in text and "Microsoft.App/" not in text, path.name
        assert "616dc9b8-b4aa-415f-8dcb-71bc462916c5" not in text, path.name
