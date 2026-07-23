#!/usr/bin/env python3
"""Fail CI on known non-functional HarmonyOS scaffolding and project drift."""

from __future__ import annotations

import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent
SOURCE = ROOT / "entry" / "src" / "main" / "ets"

forbidden = {
    r"\bpinSet\b": "nonexistent Network Kit pinSet option",
    r"\bassetStore\.": "nonexistent Asset Store API",
    r"MixedMode\.Compatibility": "insecure mixed-content compatibility mode",
    r"as\s+any\b": "ArkTS any escape",
    r"(?i)//\s*(stub|todo|placeholder)\b": "unfinished implementation marker",
}

failures: list[str] = []
for path in sorted(SOURCE.rglob("*.ets")):
    text = path.read_text(encoding="utf-8")
    for pattern, reason in forbidden.items():
        if re.search(pattern, text):
            failures.append(f"{path.relative_to(ROOT)}: {reason}")

required_snippets = {
    "core/security/CredentialStore.ets": (
        "cert.parsePkcs12",
        "asset.add",
        "CredentialStore.filesDir",
        "installPrivateCertificate",
        "createPkcs12",
    ),
    "features/setup/SetupTransaction.ets": (
        "certificatePinning",
        "clientCert",
        "config.isGatewayUrl(url)",
    ),
    "features/remote/RemoteWebPage.ets": (
        ".onShowFileSelector",
        ".onClientAuthenticationRequest",
        ".onSslErrorEvent(",
        ".onPermissionRequest",
        ".onDownloadStart",
        ".onHttpErrorReceive",
        "WebCookieManager.clearAllCookiesSync(true)",
        "WebStorage.deleteAllData(true)",
        "controller.getCertificate()",
        "controller.setUrlTrustList(",
        "controller.clearSslCache()",
        "CredentialStore.webClientAuthUri(",
        "handler.confirm(authUri",
        "incognitoMode: true",
        "cert.createX509CertChain(chain).validate(",
        "sslHostname: config.gatewayHost",
        "event.error === SslError.Untrusted",
        "maxRedirects: 0",
        "handler.ignore()",
        "this.isCurrentConnection(generation, config)",
    ),
    "core/storage/ProfileStore.ets": (
        "preferences.getPreferencesSync",
        "store.flush()",
    ),
    "core/storage/ClientSettings.ets": (
        "global_display_mode",
        "setPreferredOrientation",
        "setColorMode",
    ),
}
for relative, snippets in required_snippets.items():
    text = (SOURCE / relative).read_text(encoding="utf-8")
    for snippet in snippets:
        if snippet not in text:
            failures.append(f"{relative}: missing {snippet}")

app_root = (SOURCE / "pages" / "AppRoot.ets").read_text(encoding="utf-8")
for forbidden_root in ("Tabs(", ".tabBar(", "selectedTab", "Navigation("):
    if forbidden_root in app_root:
        failures.append(f"pages/AppRoot.ets: parallel root navigation is forbidden ({forbidden_root})")
for required_root in (
    "RootPage.CATALOG",
    "RootPage.SETTINGS",
    "RootPage.CONNECTIONS",
    "catalog_settings_button",
    "onBackPress",
    "settings_manage_connections",
):
    if required_root not in app_root and required_root != "settings_manage_connections":
        failures.append(f"pages/AppRoot.ets: missing single-stack flow marker {required_root}")

for setup_guard in (
    "private operationGeneration: number",
    "private setupOperationCompletion: Promise<void> | null",
    "private cleanupPromise: Promise<void> | null",
    "ConnectionOperationKind.DELETE",
    "private scanOwner: number",
    "interactionsEnabled: this.connectionActionsEnabled()",
):
    if setup_guard not in app_root:
        failures.append(f"pages/AppRoot.ets: missing setup serialization guard {setup_guard}")

cancel_start = app_root.find("async cancelSetup(")
cancel_end = app_root.find("\n  async handleSetupState", cancel_start)
cancel_body = app_root[cancel_start:cancel_end] if cancel_start != -1 and cancel_end != -1 else ""
cleanup_lock = cancel_body.find("this.cleanupBusy = true")
cleanup_await = cancel_body.find("await cleanup")
generation_guard = cancel_body.find("generation !== this.operationGeneration", cleanup_await)
pending_clear = cancel_body.find("this.pendingPayload = null", cleanup_await)
cleanup_failure = cancel_body.find("if (cleanupError !== null)", cleanup_await)
if not (
    -1 < cleanup_lock < cleanup_await < generation_guard < cleanup_failure < pending_clear
):
    failures.append(
        "pages/AppRoot.ets: cleanup must stay locked through await, generation check, and failure handling"
    )

cleanup_start = app_root.find("async performSetupCleanup(")
cleanup_end = app_root.find("\n  async cancelSetup(", cleanup_start)
cleanup_body = app_root[cleanup_start:cleanup_end] if cleanup_start != -1 and cleanup_end != -1 else ""
if "await transaction.cancel()" not in cleanup_body or "await setupCompletion" not in cleanup_body:
    failures.append("pages/AppRoot.ets: cleanup must await transaction and UI setup completion")

serialized_methods = (
    ("beginSetup", "retryPairing"),
    ("retryPairing", "retryActivation"),
    ("retryActivation", "retrySetup"),
    ("scanSetup", "submitSetup"),
)
for method, next_method in serialized_methods:
    start = app_root.find(f"async {method}(")
    end = app_root.find(f"\n  async {next_method}(", start)
    body = app_root[start:end] if start != -1 and end != -1 else ""
    if "++this.operationGeneration" not in body or "this.supersedeProfileSelection()" not in body:
        failures.append(f"pages/AppRoot.ets: {method} must supersede stale profile selection")

scan_start = app_root.find("async scanSetup(")
scan_end = app_root.find("\n  async submitSetup(", scan_start)
scan_body = app_root[scan_start:scan_end] if scan_start != -1 and scan_end != -1 else ""
if ("this.scanOwner = generation" not in scan_body or
        scan_body.count("this.finishOwnedScan(generation)") < 2):
    failures.append("pages/AppRoot.ets: scan completion must be owned and idempotent")

ready_start = app_root.find("if (state.kind === SetupStateKind.READY)")
ready_end = app_root.find("\n    if (state.kind === SetupStateKind.PAIRING)", ready_start)
ready_body = app_root[ready_start:ready_end] if ready_start != -1 and ready_end != -1 else ""
if ("this.activeProfile?.installationId !== state.config.installationId" not in ready_body or
        "this.currentPage = RootPage.CONNECTIONS" not in ready_body):
    failures.append("pages/AppRoot.ets: READY must reject an unusable target profile")

delete_start = app_root.find("async deleteProfile(")
delete_end = app_root.find("\n  confirmDeleteProfile", delete_start)
delete_body = app_root[delete_start:delete_end] if delete_start != -1 and delete_end != -1 else ""
if ("if (!this.connectionActionsEnabled())" not in delete_body or
        "ConnectionOperationKind.DELETE" not in delete_body):
    failures.append("pages/AppRoot.ets: profile deletion must be exclusive with setup operations")
delete_catch = delete_body.find("} catch (error) {")
delete_finally = delete_body.find("} finally {", delete_catch)
delete_recovery = (
    delete_body[delete_catch:delete_finally]
    if delete_catch != -1 and delete_finally != -1 else ""
)
if ("await this.reloadProfiles('', generation)" not in delete_recovery or
        "generation !== this.operationGeneration" not in delete_recovery):
    failures.append("pages/AppRoot.ets: failed deletion must reconcile persisted profile state")

connections_page = (
    SOURCE / "features" / "connections" / "ConnectionsPage.ets"
).read_text(encoding="utf-8")
for interaction_guard in (
    "@Prop interactionsEnabled: boolean",
    ".enabled(this.interactionsEnabled)",
):
    if interaction_guard not in connections_page:
        failures.append(
            f"features/connections/ConnectionsPage.ets: missing interaction guard {interaction_guard}"
        )

settings_page = (SOURCE / "features" / "settings" / "SettingsPage.ets").read_text(encoding="utf-8")
if "settings_manage_connections" not in settings_page:
    failures.append("features/settings/SettingsPage.ets: missing connection-management entry")

catalog_page = (SOURCE / "features" / "catalog" / "CatalogPage.ets").read_text(encoding="utf-8")
if "config: this.activeConfig" in catalog_page:
    failures.append(
        "features/catalog/CatalogPage.ets: class instances must not be passed through router params"
    )
for route_field in (
    "installationId: this.activeConfig.installationId",
    "profileName: this.activeConfig.name",
    "connectionMode: this.activeConfig.mode",
    "gatewayOrigin: this.activeConfig.gatewayOrigin",
    "gatewayFingerprint: this.activeConfig.gatewayFingerprint",
    "gatewayPublicKeyPin: this.activeConfig.gatewayPublicKeyPin",
):
    if route_field not in catalog_page:
        failures.append(f"features/catalog/CatalogPage.ets: missing primitive route field {route_field}")
request_guard = catalog_page.find("if (this.requestInFlight)")
refresh_progress = catalog_page.find("this.showRefreshProgress = true")
if request_guard == -1 or refresh_progress == -1 or request_guard > refresh_progress:
    failures.append(
        "features/catalog/CatalogPage.ets: in-flight request guard must precede refresh progress"
    )
for catalog_guard in (
    "private pageGeneration: number",
    "private isVisible: boolean",
    "private requestOwner: number",
    "requestId !== this.requestOwner",
    "this.isCurrentGeneration(generation)",
):
    if catalog_guard not in catalog_page:
        failures.append(
            f"features/catalog/CatalogPage.ets: missing lifecycle guard {catalog_guard}"
        )

authorization_start = app_root.find("async handleAuthorizationRevoked(")
authorization_end = app_root.find("\n  openSettings", authorization_start)
authorization_body = (
    app_root[authorization_start:authorization_end]
    if authorization_start != -1 and authorization_end != -1 else ""
)
authorization_catch = authorization_body.find("} catch (error) {")
authorization_finally = authorization_body.find("} finally {", authorization_catch)
authorization_recovery = (
    authorization_body[authorization_catch:authorization_finally]
    if authorization_catch != -1 and authorization_finally != -1 else ""
)
if ("await this.reloadProfiles('', generation)" not in authorization_recovery or
        "generation !== this.operationGeneration" not in authorization_recovery):
    failures.append(
        "pages/AppRoot.ets: revoked authorization removal must reconcile persisted profile state"
    )

module_manifest = (
    ROOT / "entry" / "src" / "main" / "module.json5"
).read_text(encoding="utf-8")
if '"name": "ohos.permission.ACCESS_CERT_MANAGER"' not in module_manifest:
    failures.append("entry/src/main/module.json5: missing Web client-certificate permission")

pages = json.loads(
    (ROOT / "entry" / "src" / "main" / "resources" / "base" / "profile" / "main_pages.json")
    .read_text(encoding="utf-8")
)["src"]
for expected in ("pages/AppRoot", "features/remote/RemoteWebPage"):
    if expected not in pages:
        failures.append(f"main_pages.json: missing {expected}")

required_project_files = (
    "hvigor/hvigor-config.json5",
    "entry/src/test/List.test.ets",
    "AppScope/resources/base/media/ic_launcher.svg",
    "AppScope/resources/base/element/string.json",
    "entry/src/main/resources/base/media/ic_launcher.svg",
)
for relative in required_project_files:
    if not (ROOT / relative).is_file():
        failures.append(f"missing project file: {relative}")

if failures:
    raise SystemExit("\n".join(failures))
print("HarmonyOS source audit passed.")
