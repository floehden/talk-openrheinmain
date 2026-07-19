#!/usr/bin/env python3
"""
Render gNMIc Target manifests from Infrahub (the single source of truth).

This script is DECLARATIVE: it queries the full set of devices from Infrahub
and rewrites the entire targets file. Devices removed from Infrahub simply do
not appear in the output, so the subsequent git commit deletes them from the
repo. Nothing here appends or diffs — the output is a pure function of the
current Infrahub state.

Environment variables:
  INFRAHUB_ADDRESS        e.g. http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000
  INFRAHUB_API_TOKEN      admin/API token
  TARGET_HOST_IP          host IP the gNMIc container dials (default 192.168.139.126)
  OUTPUT_FILE             where to write (default 02-targets.yaml)
"""
import os
import sys
import asyncio

from infrahub_sdk import InfrahubClient, Config

# containerlab host-side gNMI port mapping per device (57400 inside -> 574NN on host)
# Adjust here if your clab port scheme changes.
DEVICE_PORTS = {
    "spine1": 57401,
    "spine2": 57402,
    "leaf1": 57411,
    "leaf2": 57412,
    "leaf3": 57413,
}

TARGET_HOST_IP = os.environ.get("TARGET_HOST_IP", "192.168.139.126")
OUTPUT_FILE = os.environ.get("OUTPUT_FILE", "02-targets.yaml")

# Static header: profile + subscriptions live with the generated targets because
# they are logically part of "what we scrape". The cluster/output/pipeline/
# monitoring manifests are hand-managed in separate files and never touched here.
HEADER = """\
# ---------------------------------------------------------------------------
# GENERATED FILE — DO NOT EDIT BY HAND.
# Rendered from Infrahub by render_targets.py. Any manual change will be
# overwritten on the next sync. Infrahub is the single source of truth.
# ---------------------------------------------------------------------------
apiVersion: operator.gnmic.dev/v1alpha1
kind: TargetProfile
metadata:
  name: default-profile
  namespace: default
spec:
  credentialsRef: device-credentials
  tls: {}
  timeout: 10s
  encoding: JSON_IETF
"""

TARGET_TMPL = """\
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Target
metadata:
  name: {name}
  namespace: default
  labels:
    role: {role}
spec:
  address: {host}:{port}
  profile: default-profile
"""

SUBSCRIPTIONS = """\
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Subscription
metadata:
  name: interface-stats
  namespace: default
  labels:
    type: interfaces
spec:
  paths:
    - /interface/statistics
    - /interface/oper-state
  mode: STREAM/SAMPLE
  sampleInterval: 5s
  encoding: JSON_IETF
---
apiVersion: operator.gnmic.dev/v1alpha1
kind: Subscription
metadata:
  name: system-stats
  namespace: default
  labels:
    type: system
spec:
  paths:
    - /platform/control[slot=A]/cpu[index=all]/total
  mode: STREAM/SAMPLE
  sampleInterval: 10s
  encoding: JSON_IETF
"""


async def fetch_devices(client):
    """Return list of (name, role) for every TopologyDevice in Infrahub."""
    devices = await client.all(kind="TopologyDevice", prefetch_relationships=True)
    result = []
    for dev in devices:
        name = dev.name.value
        role = None
        # role is a relationship to TopologyRole; resolve its name
        if dev.role.peer:
            role = dev.role.peer.name.value
        result.append((name, role))
    return result


async def main():
    client = InfrahubClient(
        address=os.environ["INFRAHUB_ADDRESS"],
        config=Config(api_token=os.environ["INFRAHUB_API_TOKEN"]),
    )

    devices = await fetch_devices(client)
    devices.sort(key=lambda d: d[0])  # stable ordering -> clean git diffs

    if not devices:
        print("WARNING: Infrahub returned zero devices.", file=sys.stderr)
        print("Refusing to render an empty target file (safety guard).", file=sys.stderr)
        print("If you really intend to remove ALL targets, set ALLOW_EMPTY=1.", file=sys.stderr)
        if os.environ.get("ALLOW_EMPTY") != "1":
            sys.exit(2)

    blocks = [HEADER]
    skipped = []
    for name, role in devices:
        port = DEVICE_PORTS.get(name)
        if port is None:
            skipped.append(name)
            continue
        blocks.append(
            TARGET_TMPL.format(
                name=name,
                role=role or "unknown",
                host=TARGET_HOST_IP,
                port=port,
            )
        )
    blocks.append(SUBSCRIPTIONS)

    with open(OUTPUT_FILE, "w") as f:
        f.write("".join(blocks))

    rendered = [d[0] for d in devices if d[0] in DEVICE_PORTS]
    print(f"Rendered {len(rendered)} targets -> {OUTPUT_FILE}: {', '.join(rendered)}")
    if skipped:
        print(f"NOTE: no port mapping for {', '.join(skipped)} — skipped. "
              f"Add them to DEVICE_PORTS.", file=sys.stderr)


if __name__ == "__main__":
    asyncio.run(main())