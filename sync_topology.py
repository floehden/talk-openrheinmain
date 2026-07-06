import yaml
import asyncio
from infrahub_sdk import InfrahubClient

async def main():
    # Connect to the local Infrahub instance
    client = InfrahubClient(address="http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000")
    
    print("🔗 1. Connecting Infrahub to Gitea Repository...")
    # This creates the Git repository link inside Infrahub's Source of Truth
    repo = await client.create(
        kind="CoreRepository",
        name="infrahub-sync",
        location="http://gitea-http.gitea.svc.cluster.local:3000/admin/infrahub-sync.git",
        commit="main"
    )
    await repo.save()
    print("   ✅ Repository Linked!")

    print("\n📖 2. Parsing Containerlab Topology...")
    with open("YAML/st.clab.yml", "r") as f:
        clab = yaml.safe_load(f)

    print("\n🏗️ 3. Creating Platforms and Roles...")
    platform_srl = await client.create(kind="TopologyPlatform", name="nokia_srlinux")
    await platform_srl.save()

    role_spine = await client.create(kind="TopologyRole", name="spine")
    await role_spine.save()

    role_leaf = await client.create(kind="TopologyRole", name="leaf")
    await role_leaf.save()

    print("\n🖥️ 4. Creating Devices...")
    device_objs = {}
    for node_name, node_data in clab.get("nodes", {}).items():
        group = node_data.get("group", "")
        # We ONLY want to import Spines and Leafs (ignoring telemetry and clients)
        if group in ["spine", "leaf"]:
            dev = await client.create(kind="TopologyDevice", name=node_name)
            dev.platform = platform_srl
            dev.role = role_spine if group == "spine" else role_leaf
            await dev.save()
            device_objs[node_name] = dev
            print(f"   Created {group.capitalize()}: {node_name}")

    print("\n🔌 5. Creating Interfaces and Wiring Connections...")
    interfaces_created = {}

    # Helper function to avoid creating duplicate interfaces
    async def get_or_create_intf(device_name, intf_name):
        if device_name not in interfaces_created:
            interfaces_created[device_name] = {}
        if intf_name not in interfaces_created[device_name]:
            intf = await client.create(kind="TopologyInterface", name=intf_name)
            intf.device = device_objs[device_name]
            await intf.save()
            interfaces_created[device_name][intf_name] = intf
        return interfaces_created[device_name][intf_name]

    # Process the physical cabling
    for link in clab.get("links", []):
        endpoints = link.get("endpoints")
        if not endpoints or len(endpoints) != 2:
            continue

        dev1_name, intf1_name = endpoints[0].split(":")
        dev2_name, intf2_name = endpoints[1].split(":")

        # We only create the link if BOTH ends are routers we care about
        if dev1_name in device_objs and dev2_name in device_objs:
            intf1 = await get_or_create_intf(dev1_name, intf1_name)
            intf2 = await get_or_create_intf(dev2_name, intf2_name)

            # Map the bidirectional connection in the Graph DB
            intf1.connected_endpoint = intf2
            await intf1.save()
            print(f"   Linked {dev1_name} ({intf1_name}) <---> {dev2_name} ({intf2_name})")

    print("\n🎉 Success! Containerlab topology is now live in Infrahub!")

if __name__ == "__main__":
    asyncio.run(main())