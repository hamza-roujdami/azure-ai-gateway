import copy

import pytest

from check_gateway import evaluate
from teams import GATEWAY_USER, MODELS_USER

GATEWAY = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.ApiManagement/aigateways/gw"
WORKSPACE = f"{GATEWAY}/workspaces/default"
MODEL = f"{WORKSPACE}/modelProviders/foundry/models/gpt"


def policies(*types):
    return {"policies": [{"type": t} for t in types]}


GOOD = {
    "gateway": {"id": GATEWAY, "properties": {"publicNetworkAccess": "Enabled"}},
    "apiKeys": [],
    "roleAssignments": [
        {"scope": f"{WORKSPACE}/aliases/chat", "principalId": "p1", "roleDefinitionId": f"/x/{MODELS_USER}"},
        {"scope": GATEWAY, "principalId": "p2", "roleDefinitionId": "/x/7c27cbcc-1723-4201-8fbc-50f2e2c24ee5"},
    ],
    "workspaces": [
        {
            "id": WORKSPACE,
            "properties": {},
            "aliases": [
                {
                    "name": "chat",
                    "properties": {"backendModels": [{"resourceId": MODEL}], **policies("costLimit")},
                }
            ],
            "models": [{"id": MODEL, "properties": policies("tokenLimit", "contentSafety")}],
            "modelProviders": [{"name": "foundry", "properties": {"authentication": {"managedIdentity": {}}}}],
            "toolServers": [{"name": "orders", "properties": policies("requestRateLimit")}],
            "telemetryExporters": [{"name": "appinsights", "properties": {"payloadCapture": False}}],
        }
    ],
}


def statuses(snapshot, **kwargs):
    return {(f.check, f.status) for f in evaluate(snapshot, **kwargs)}


def test_a_governed_gateway_passes_with_inherited_policies():
    assert all(status == "PASS" for _, status in statuses(GOOD))


@pytest.mark.parametrize(
    ("change", "check"),
    [
        (lambda s: s["apiKeys"].append({"name": "app-key", "properties": {"state": "active"}}), "no-runtime-api-keys"),
        (
            lambda s: s["roleAssignments"].append(
                {"scope": "/subscriptions/s", "principalId": "p3", "roleDefinitionId": f"/x/{MODELS_USER}"}
            ),
            "runtime-roles-scoped",
        ),
        (
            lambda s: s["roleAssignments"].append(
                {"scope": WORKSPACE, "principalId": "p4", "roleDefinitionId": f"/x/{GATEWAY_USER}"}
            ),
            "runtime-roles-scoped",
        ),
        (
            lambda s: s["roleAssignments"].append(
                {
                    "scope": "/providers/Microsoft.Management/managementGroups/mg1",
                    "principalId": "p5",
                    "roleDefinitionId": f"/x/{GATEWAY_USER}",
                }
            ),
            "runtime-roles-scoped",
        ),
        (lambda s: s["workspaces"][0]["models"][0]["properties"].update(policies("tokenLimit")), "content-safety"),
        (lambda s: s["workspaces"][0]["toolServers"][0]["properties"].update(policies()), "tool-limits"),
        (
            lambda s: s["workspaces"][0]["telemetryExporters"][0]["properties"].update(payloadCapture=True),
            "telemetry",
        ),
    ],
)
def test_ungoverned_settings_fail(change, check):
    snapshot = copy.deepcopy(GOOD)
    change(snapshot)
    assert (check, "FAIL") in statuses(snapshot)


def test_workspace_rate_limit_covers_mcp_servers():
    snapshot = copy.deepcopy(GOOD)
    snapshot["workspaces"][0]["properties"] = policies("requestRateLimit")
    snapshot["workspaces"][0]["toolServers"][0]["properties"] = {}
    assert ("tool-limits", "PASS") in statuses(snapshot)


def test_a_suspended_master_key_passes():
    snapshot = copy.deepcopy(GOOD)
    snapshot["apiKeys"].append({"name": "master", "properties": {"state": "suspended"}})
    assert ("no-runtime-api-keys", "PASS") in statuses(snapshot)


def test_public_access_fails_only_when_private_is_expected():
    assert ("public-access", "PASS") in statuses(GOOD)
    assert ("public-access", "FAIL") in statuses(GOOD, expect_private=True)
