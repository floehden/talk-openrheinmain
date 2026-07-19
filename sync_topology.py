import os
import yaml
import asyncio
from infrahub_sdk import InfrahubClient, Config

CLAB_FILE = "YAML/st.clab.yml"
REPO_LOCATION = "http://gitea-http.gitea.svc.cluster.local:3000/admin/infrahub-sync.git"

# Which containerlab groups we import as network devices
DEVICE_GROUPS = {"spine", "leaf"}


async def get_or_create(client, kind, name, **attrs):
    """Return an existing node by name, or create it. Keeps the script idempotent."""
    existing = await client.filters(kind=kind, name__value=name)
    if existing:
        return existing[0]
    obj = await client.create(kind=kind, name=name, **attrs)
    await obj.save()
    return obj


async def main():
    client = InfrahubClient(
        address=os.environ["INFRAHUB_ADDRESS"],
        config=Config(api_token=os.environ["INFRAHUB_API_TOKEN"]),
    )

    print("🔗 1. Connecting Infrahub to Gitea Repository...")
    existing_repo = await client.filters(kind="CoreRepository", name__value="infrahub-sync")
    if existing_repo:
        print("   ℹ️ Repository already linked, skipping.")
    else:
        repo = await client.create(
            kind="CoreRepository",
            name="infrahub-sync",
            location=REPO_LOCATION,
            commit="main",
        )
        await repo.save()
        print("   ✅ Repository Linked!")

    print("\n📖 2. Parsing Containerlab Topology...")
    with open(CLAB_FILE, "r") as f:
        clab = yaml.safe_load(f)

    # In containerlab, nodes and links live UNDER the `topology` key
    topology = clab.get("topology", {})
    nodes = topology.get("nodes", {})
    links = topology.get("links", [])
    print(f"   Found {len(nodes)} nodes and {len(links)} links in the topology.")

    print("\n🏗️ 3. Creating Platforms and Roles...")
    platform_srl = await get_or_create(client, "TopologyPlatform", "nokia_srlinux")
    role_spine = await get_or_create(client, "TopologyRole", "spine")
    role_leaf = await get_or_create(client, "TopologyRole", "leaf")
    roles = {"spine": role_spine, "leaf": role_leaf}

    print("\n🖥️ 4. Creating Devices...")
    device_objs = {}
    for node_name, node_data in nodes.items():
        group = node_data.get("group", "")
        # Only import spines and leafs (ignore clients, telemetry, logging)
        if group in DEVICE_GROUPS:
            dev = await get_or_create(client, "TopologyDevice", node_name)
            dev.platform = platform_srl
            dev.role = roles[group]
            await dev.save()
            device_objs[node_name] = dev
            print(f"   Created {group.capitalize()}: {node_name}")

    print("\n🔌 5. Creating Interfaces and Wiring Connections...")
    interfaces_created = {}

    async def get_or_create_intf(device_name, intf_name):
        interfaces_created.setdefault(device_name, {})
        if intf_name not in interfaces_created[device_name]:
            intf = await client.create(
                kind="TopologyInterface",
                name=intf_name,
                device=device_objs[device_name],
            )
            await intf.save()
            interfaces_created[device_name][intf_name] = intf
        return interfaces_created[device_name][intf_name]

    for link in links:
        endpoints = link.get("endpoints")
        if not endpoints or len(endpoints) != 2:
            continue

        dev1_name, intf1_name = endpoints[0].split(":")
        dev2_name, intf2_name = endpoints[1].split(":")

        # Only wire links where BOTH ends are devices we imported
        if dev1_name in device_objs and dev2_name in device_objs:
            intf1 = await get_or_create_intf(dev1_name, intf1_name)
            intf2 = await get_or_create_intf(dev2_name, intf2_name)

            intf1.connected_endpoint = intf2
            await intf1.save()
            print(f"   Linked {dev1_name} ({intf1_name}) <---> {dev2_name} ({intf2_name})")

    print("\n🎉 Success! Containerlab topology is now live in Infrahub!")


if __name__ == "__main__":
    asyncio.run(main())