#!/usr/bin/env python3
import argparse
import ipaddress
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape as xml_escape


ASSETS = Path(__file__).resolve().parent.parent / "assets"
HEX64 = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER = re.compile(r"^[a-z0-9][a-z0-9._-]{0,63}$")
USER = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*\$?$")
SID = re.compile(r"^S-1-[0-9-]+$")
PLACEHOLDER = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
HOSTNAME = re.compile(r"^(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
LOOPBACK_UPSTREAM = re.compile(r"^127\.0\.0\.1:([0-9]{1,5})$")


def fail(message):
    raise ValueError(message)


def load_values(path, required):
    if path == "-":
        values = json.load(sys.stdin)
    else:
        with open(path, encoding="utf-8") as source:
            values = json.load(source)
    if not isinstance(values, dict) or set(values) != set(required):
        fail("input keys must be exactly: " + ", ".join(sorted(required)))
    return values


def text(value, name):
    if not isinstance(value, str) or not value or any(ord(char) < 32 for char in value):
        fail(f"{name} must be a non-empty string without control characters")
    return value


def arguments(value):
    if not isinstance(value, list):
        fail("arguments must be an array")
    return [text(item, "argument") for item in value]


def absolute(value, name, windows=False):
    value = text(value, name)
    if windows:
        if not re.match(r"^[A-Za-z]:\\", value):
            fail(f"{name} must be an absolute Windows path")
    elif not value.startswith("/"):
        fail(f"{name} must be an absolute POSIX path")
    return value


def portable_absolute(value, name):
    value = text(value, name)
    if not value.startswith("/") and not re.match(r"^[A-Za-z]:\\", value):
        fail(f"{name} must be an absolute path")
    return value


def hostname(value, name):
    value = text(value, name)
    if not HOSTNAME.fullmatch(value):
        fail(f"{name} must be a DNS hostname")
    return value


def loopback_upstream(value, name):
    value = text(value, name)
    match = LOOPBACK_UPSTREAM.fullmatch(value)
    if not match or not 1024 <= int(match.group(1)) <= 65535:
        fail(f"{name} must be a loopback high-port address")
    return value


def read_template(name):
    return (ASSETS / name).read_text(encoding="utf-8")


def replace(template, values):
    names = set(PLACEHOLDER.findall(template))
    if names != set(values):
        fail("template values do not match placeholders")
    rendered = PLACEHOLDER.sub(lambda match: values[match.group(1)], template)
    if PLACEHOLDER.search(rendered):
        fail("unrendered placeholder")
    return rendered


def atomic_write(path, contents, encoding="utf-8"):
    output = Path(path).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_name(output.name + ".tmp")
    temporary.write_text(contents, encoding=encoding, newline="\n")
    os.replace(temporary, output)


def systemd_quote(value):
    value = value.replace("%", "%%").replace("\\", "\\\\").replace('"', '\\"')
    return f'"{value}"'


def systemd_exec_quote(value):
    return systemd_quote(value.replace("$", "$$"))


def systemd_path(value, name):
    value = absolute(value, name)
    rendered = []
    for character in value:
        if character == "%":
            rendered.append("%%")
        elif character == "\\":
            rendered.append("\\\\")
        elif character.isascii() and (character.isalnum() or character in "/._:-"):
            rendered.append(character)
        else:
            rendered.extend(f"\\x{byte:02x}" for byte in character.encode("utf-8"))
    return "".join(rendered)


def render_systemd(input_path, output):
    keys = {"installation_id", "component_id", "user", "working_directory", "executable", "arguments", "log_file"}
    value = load_values(input_path, keys)
    if not HEX64.fullmatch(value["installation_id"]) or not IDENTIFIER.fullmatch(value["component_id"]):
        fail("invalid installation_id or component_id")
    if not isinstance(value["user"], str) or not USER.fullmatch(value["user"]):
        fail("invalid service user")
    args = arguments(value["arguments"])
    fields = {
        "INSTALLATION_ID": value["installation_id"], "COMPONENT_ID": value["component_id"], "USER": value["user"],
        "WORKING_DIRECTORY": systemd_path(value["working_directory"], "working_directory"),
        "EXECUTABLE": systemd_exec_quote(absolute(value["executable"], "executable")),
        "ARGUMENTS": " ".join(systemd_exec_quote(item) for item in args),
        "LOG_FILE": systemd_path(value["log_file"], "log_file"),
    }
    atomic_write(output, replace(read_template("systemd.service.tmpl"), fields))


def render_systemd_user(input_path, output):
    keys = {"installation_id", "component_id", "working_directory", "executable", "arguments", "log_file"}
    value = load_values(input_path, keys)
    if not HEX64.fullmatch(value["installation_id"]) or not IDENTIFIER.fullmatch(value["component_id"]):
        fail("invalid installation_id or component_id")
    fields = {
        "INSTALLATION_ID": value["installation_id"], "COMPONENT_ID": value["component_id"],
        "WORKING_DIRECTORY": systemd_path(value["working_directory"], "working_directory"),
        "EXECUTABLE": systemd_exec_quote(absolute(value["executable"], "executable")),
        "ARGUMENTS": " ".join(systemd_exec_quote(item) for item in arguments(value["arguments"])),
        "LOG_FILE": systemd_path(value["log_file"], "log_file"),
    }
    atomic_write(output, replace(read_template("systemd-user.service.tmpl"), fields))


def render_caddy_systemd(input_path, output):
    keys = {"installation_id", "user", "working_directory", "executable", "arguments", "data_directory", "config_directory", "config_file", "log_file"}
    value = load_values(input_path, keys)
    if not HEX64.fullmatch(value["installation_id"]):
        fail("invalid installation_id")
    if not isinstance(value["user"], str) or not USER.fullmatch(value["user"]):
        fail("invalid service user")
    fields = {
        "INSTALLATION_ID": value["installation_id"], "USER": value["user"],
        "WORKING_DIRECTORY": systemd_path(value["working_directory"], "working_directory"),
        "CADDY_DATA_ENV": systemd_quote("XDG_DATA_HOME=" + absolute(value["data_directory"], "data_directory")),
        "CADDY_CONFIG_ENV": systemd_quote("XDG_CONFIG_HOME=" + absolute(value["config_directory"], "config_directory")),
        "EXECUTABLE": systemd_exec_quote(absolute(value["executable"], "executable")),
        "ARGUMENTS": " ".join(systemd_exec_quote(item) for item in arguments(value["arguments"])),
        "CONFIG_FILE": systemd_exec_quote(absolute(value["config_file"], "config_file")),
        "LOG_FILE": systemd_path(value["log_file"], "log_file"),
    }
    atomic_write(output, replace(read_template("caddy-systemd.service.tmpl"), fields))


def render_launchd(input_path, output):
    keys = {"installation_id", "component_id", "working_directory", "executable", "arguments", "log_file"}
    value = load_values(input_path, keys)
    if not HEX64.fullmatch(value["installation_id"]) or not IDENTIFIER.fullmatch(value["component_id"]):
        fail("invalid installation_id or component_id")
    program = [absolute(value["executable"], "executable"), *arguments(value["arguments"])]
    fields = {
        "INSTALLATION_ID": value["installation_id"], "COMPONENT_ID": value["component_id"],
        "PROGRAM_ARGUMENT_STRINGS": "".join(f"<string>{xml_escape(item)}</string>" for item in program),
        "WORKING_DIRECTORY": xml_escape(absolute(value["working_directory"], "working_directory")),
        "LOG_FILE": xml_escape(absolute(value["log_file"], "log_file")),
    }
    atomic_write(output, replace(read_template("launchd.plist.tmpl"), fields))


def render_windows(input_path, output, launcher_output):
    keys = {"installation_id", "component_id", "user_sid", "working_directory", "wscript", "executable", "arguments"}
    value = load_values(input_path, keys)
    if not HEX64.fullmatch(value["installation_id"]) or not IDENTIFIER.fullmatch(value["component_id"]):
        fail("invalid installation_id or component_id")
    if not isinstance(value["user_sid"], str) or not SID.fullmatch(value["user_sid"]):
        fail("invalid Windows user SID")
    executable = absolute(value["executable"], "executable", windows=True)
    command_line = subprocess.list2cmdline([executable, *arguments(value["arguments"])]).replace('"', '""')
    launcher = replace(read_template("hidden-launcher.vbs.tmpl"), {"COMMAND_LINE": command_line})
    atomic_write(launcher_output, launcher, encoding="utf-16")
    fields = {
        "INSTALLATION_ID": value["installation_id"], "COMPONENT_ID": value["component_id"],
        "USER_SID": value["user_sid"], "WSCRIPT": xml_escape(absolute(value["wscript"], "wscript", windows=True)),
        "HIDDEN_LAUNCHER_VBS": xml_escape(str(Path(launcher_output).resolve())),
        "WORKING_DIRECTORY": xml_escape(absolute(value["working_directory"], "working_directory", windows=True)),
    }
    atomic_write(output, replace(read_template("scheduled-task.xml.tmpl"), fields), encoding="utf-16")


def toml_string(value, name):
    return json.dumps(text(value, name), ensure_ascii=False)[1:-1]


def port(value, name):
    if not isinstance(value, int) or isinstance(value, bool) or not 1024 <= value <= 65535:
        fail(f"{name} must be an integer port")
    return str(value)


def render_frp(kind, input_path, output):
    if kind == "frps":
        keys = {"frps_port", "frps_token_file", "frps_log"}
        value = load_values(input_path, keys)
        fields = {
            "FRPS_PORT": port(value["frps_port"], "frps_port"),
            "FRPS_TOKEN_FILE": toml_string(portable_absolute(value["frps_token_file"], "frps_token_file"), "frps_token_file"),
            "FRPS_LOG": toml_string(portable_absolute(value["frps_log"], "frps_log"), "frps_log"),
        }
    else:
        keys = {"public_host", "tunnel_client_cert", "tunnel_client_key", "frps_token_file", "frpc_log", "installation_id", "node_port", "node_tunnel_port"}
        value = load_values(input_path, keys)
        if not HEX64.fullmatch(value["installation_id"]):
            fail("invalid installation_id")
        fields = {
            "PUBLIC_HOST": toml_string(hostname(value["public_host"], "public_host"), "public_host"),
            "TUNNEL_CLIENT_CERT": toml_string(portable_absolute(value["tunnel_client_cert"], "tunnel_client_cert"), "tunnel_client_cert"),
            "TUNNEL_CLIENT_KEY": toml_string(portable_absolute(value["tunnel_client_key"], "tunnel_client_key"), "tunnel_client_key"),
            "FRPS_TOKEN_FILE": toml_string(portable_absolute(value["frps_token_file"], "frps_token_file"), "frps_token_file"),
            "FRPC_LOG": toml_string(portable_absolute(value["frpc_log"], "frpc_log"), "frpc_log"),
            "INSTALLATION_ID": value["installation_id"], "NODE_PORT": port(value["node_port"], "node_port"), "NODE_TUNNEL_PORT": port(value["node_tunnel_port"], "node_tunnel_port"),
        }
    atomic_write(output, replace(read_template(kind + ".toml.tmpl"), fields))


def caddy_token(value, name):
    value = text(value, name)
    if "{" in value or "}" in value:
        fail(f"{name} cannot contain Caddy placeholders")
    return value.replace("\\", "\\\\").replace('"', '\\"')


def render_caddy(input_path, output):
    keys = {"public_host", "device_ca_file", "tunnel_ca_file", "pairing_upstream", "frps_upstream", "status_upstream", "tunnel_issuer_dn", "device_issuer_dn"}
    value = load_values(input_path, keys)
    public_host = hostname(value["public_host"], "public_host")
    try:
        ipaddress.ip_address(public_host)
        acme_profile = "profile shortlived"
        default_sni = "default_sni " + public_host
        strict_sni_host = "servers {\n\t\tstrict_sni_host insecure_off\n\t}"
    except ValueError:
        acme_profile = ""
        default_sni = ""
        strict_sni_host = ""
    fields = {
        "PUBLIC_HOST": public_host,
        "ACME_PROFILE": acme_profile,
        "DEFAULT_SNI": default_sni,
        "STRICT_SNI_HOST": strict_sni_host,
        "DEVICE_CA_FILE": caddy_token(absolute(value["device_ca_file"], "device_ca_file"), "device_ca_file"),
        "TUNNEL_CA_FILE": caddy_token(absolute(value["tunnel_ca_file"], "tunnel_ca_file"), "tunnel_ca_file"),
        "PAIRING_UPSTREAM": loopback_upstream(value["pairing_upstream"], "pairing_upstream"),
        "FRPS_UPSTREAM": loopback_upstream(value["frps_upstream"], "frps_upstream"),
        "STATUS_UPSTREAM": loopback_upstream(value["status_upstream"], "status_upstream"),
        "TUNNEL_ISSUER_DN": caddy_token(value["tunnel_issuer_dn"], "tunnel_issuer_dn"),
        "DEVICE_ISSUER_DN": caddy_token(value["device_issuer_dn"], "device_issuer_dn"),
    }
    atomic_write(output, replace(read_template("Caddyfile.tmpl"), fields))


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="kind", required=True)
    for kind in ("systemd", "systemd-user", "caddy-systemd", "launchd", "frpc", "frps", "caddy"):
        command = subparsers.add_parser(kind)
        command.add_argument("--input", required=True)
        command.add_argument("--output", required=True)
    windows = subparsers.add_parser("windows")
    windows.add_argument("--input", required=True)
    windows.add_argument("--output", required=True)
    windows.add_argument("--launcher-output", required=True)
    args = parser.parse_args()
    try:
        if args.kind == "systemd": render_systemd(args.input, args.output)
        elif args.kind == "systemd-user": render_systemd_user(args.input, args.output)
        elif args.kind == "caddy-systemd": render_caddy_systemd(args.input, args.output)
        elif args.kind == "launchd": render_launchd(args.input, args.output)
        elif args.kind == "windows": render_windows(args.input, args.output, args.launcher_output)
        elif args.kind in ("frpc", "frps"): render_frp(args.kind, args.input, args.output)
        else: render_caddy(args.input, args.output)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
