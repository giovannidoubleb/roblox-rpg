"""Packages src/ into dist/CityGrind.rbxlx and dist/CityGrind_Install.luau."""
import os
from xml.sax.saxutils import escape

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
DIST = os.path.join(ROOT, "dist")

def read(rel):
    with open(os.path.join(SRC, rel), encoding="utf-8") as f:
        return f.read()

def modules(folder, skip):
    """Every .luau module in src/<folder>, sorted, except the entry script."""
    names = sorted(f for f in os.listdir(os.path.join(SRC, folder)) if f.endswith(".luau") and f != skip)
    return [(n[:-5], f"{folder}/{n}") for n in names]

SHARED = modules("shared", None)
SERVER = modules("server", "Main.server.luau")
CLIENT = modules("client", "Client.client.luau")

# (service, [path inside service], className, name, source file, children)
TREE = [
    ("ReplicatedStorage", [("Folder", "CityGrind", None, [
        ("ModuleScript", n, f, []) for n, f in SHARED
    ])]),
    ("ServerScriptService", [("Script", "CityGrindServer", "server/Main.server.luau", [
        ("ModuleScript", n, f, []) for n, f in SERVER
    ])]),
    ("StarterPlayer", [("StarterPlayerScripts", "StarterPlayerScripts", None, [
        ("LocalScript", "CityGrindClient", "client/Client.client.luau", [
            ("ModuleScript", n, f, []) for n, f in CLIENT
        ]),
    ])]),
]

ref = 0
def next_ref():
    global ref
    ref += 1
    return f"RBX{ref:08X}"

def cdata(text):
    return "<![CDATA[" + text.replace("]]>", "]]]]><![CDATA[>") + "]]>"

def item_xml(cls, name, src, children, indent):
    pad = "  " * indent
    out = [f'{pad}<Item class="{cls}" referent="{next_ref()}">', f"{pad}  <Properties>",
           f'{pad}    <string name="Name">{escape(name)}</string>']
    if src:
        out.append(f'{pad}    <ProtectedString name="Source">{cdata(read(src))}</ProtectedString>')
    out.append(f"{pad}  </Properties>")
    for c in children:
        out.append(item_xml(*c, indent + 1))
    out.append(f"{pad}</Item>")
    return "\n".join(out)

def build_rbxlx():
    parts = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" version="4">']
    parts.append(f'  <Item class="Workspace" referent="{next_ref()}"><Properties><string name="Name">Workspace</string></Properties></Item>')
    # Future lighting (Enum.Technology.Future = 3); scripts can't set this at runtime.
    parts.append(f'  <Item class="Lighting" referent="{next_ref()}"><Properties><string name="Name">Lighting</string><token name="Technology">3</token></Properties></Item>')
    for service, children in TREE:
        extra = '<bool name="EnableMouseLockOption">false</bool>' if service == "StarterPlayer" else ""
        parts.append(f'  <Item class="{service}" referent="{next_ref()}"><Properties><string name="Name">{service}</string>{extra}</Properties>')
        for c in children:
            parts.append(item_xml(*c, 2))
        parts.append("  </Item>")
    parts.append("</roblox>")
    return "\n".join(parts) + "\n"

def build_installer():
    lines = [
        "-- CITY GRIND installer. Paste all of this into Studio's Command Bar",
        "-- (View > Command Bar) and press Enter. Re-running it updates the scripts in place.",
        "local function put(parent, className, name, source)",
        "\tlocal existing = parent:FindFirstChild(name)",
        "\tif existing and existing.ClassName ~= className then existing:Destroy() existing = nil end",
        "\tlocal inst = existing or Instance.new(className)",
        "\tinst.Name = name",
        "\tif source then inst.Source = source end",
        "\tinst.Parent = parent",
        "\treturn inst",
        "end",
        "local RS = game:GetService('ReplicatedStorage')",
        "local SSS = game:GetService('ServerScriptService')",
        "local SP = game:GetService('StarterPlayer')",
        "SP.EnableMouseLockOption = false",
        "local SPS = SP:FindFirstChildOfClass('StarterPlayerScripts')",
    ]
    def lit(src):
        body = read(src)
        assert "]=====]" not in body
        return "[=====[\n" + body + "]=====]"
    lines.append("local folder = put(RS, 'Folder', 'CityGrind', nil)")
    for n, f in SHARED:
        lines.append(f"put(folder, 'ModuleScript', '{n}', {lit(f)})")
    lines.append(f"local server = put(SSS, 'Script', 'CityGrindServer', {lit('server/Main.server.luau')})")
    for n, f in SERVER:
        lines.append(f"put(server, 'ModuleScript', '{n}', {lit(f)})")
    lines.append(f"local client = put(SPS, 'LocalScript', 'CityGrindClient', {lit('client/Client.client.luau')})")
    for n, f in CLIENT:
        lines.append(f"put(client, 'ModuleScript', '{n}', {lit(f)})")
    lines.append("pcall(function() game:GetService('Lighting').Technology = Enum.Technology.Future end)")
    lines.append("print('[CityGrind] Installed. Press Play to build the Neighborhood and test.')")
    return "\n".join(lines) + "\n"

def build_project():
    import json
    def mods(lst):
        return {n: {"$path": "src/" + f} for n, f in lst}
    tree = {
        "$className": "DataModel",
        "ReplicatedStorage": {"CityGrind": dict({"$className": "Folder"}, **mods(SHARED))},
        "ServerScriptService": {"CityGrindServer": dict({"$path": "src/server/Main.server.luau"}, **mods(SERVER))},
        "StarterPlayer": {
            "$properties": {"EnableMouseLockOption": False},
            "StarterPlayerScripts": {"CityGrindClient": dict({"$path": "src/client/Client.client.luau"}, **mods(CLIENT))},
        },
    }
    return json.dumps({"name": "city-grind", "tree": tree}, indent=2) + "\n"

with open(os.path.join(ROOT, "default.project.json"), "w", encoding="utf-8") as f:
    f.write(build_project())
os.makedirs(DIST, exist_ok=True)
with open(os.path.join(DIST, "CityGrind.rbxlx"), "w", encoding="utf-8") as f:
    f.write(build_rbxlx())
with open(os.path.join(DIST, "CityGrind_Install.luau"), "w", encoding="utf-8") as f:
    f.write(build_installer())
print("built", os.listdir(DIST))
