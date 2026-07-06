import os
import urllib.request
import urllib.error

address = os.environ.get("INFRAHUB_ADDRESS", "http://infrahub-infrahub-server.infrahub.svc.cluster.local:8000")
# THE MAGIC FIX: Strip the invisible trailing newline from bash!
token = os.environ.get("INFRAHUB_API_TOKEN").strip()

with open("YAML/schema.yml", "rb") as f:
    yaml_data = f.read()

print(f"🔗 Hitting API directly: {address}/api/schema/load?branch=main")

req = urllib.request.Request(f"{address}/api/schema/load?branch=main", data=yaml_data)
# Back to the correct header:
req.add_header("Authorization", f"Bearer {token}")
req.add_header("Content-Type", "application/vnd.infrahub.schema+yaml") 

try:
    response = urllib.request.urlopen(req)
    print("\n✅ Success! Schema loaded perfectly.")
    print(response.read().decode())
except urllib.error.HTTPError as e:
    print(f"\n❌ SERVER REJECTED THE SCHEMA (HTTP {e.code}):")
    print(e.read().decode())
except Exception as e:
    print(f"\n❌ OTHER ERROR: {repr(e)}")