r"""
Dumps the official winget source index (index.db of source.msix) as JSON for Tools\Update-WingetMap.ps1.
One record per package id (latest version): id, name, moniker, version, manifest folder, tags, commands, normalized publisher.
Usage: python -I Export-WingetIndex.py <index.db> <out.json>
"""
import json
import re
import sqlite3
import sys


def version_key(version):
    # numeric parts compare as numbers, anything else as text: good enough to find the latest of a package
    return [(0, int(p), "") if p.isdigit() else (1, 0, p) for p in re.split(r"[.\-+_ ]", version or "") if p != ""]


def main(db_path, out_path):
    con = sqlite3.connect("file:%s?mode=ro" % db_path, uri=True)
    parts = {r[0]: (r[1], r[2]) for r in con.execute("select rowid, parent, pathpart from pathparts")}

    def path_of(row):
        out = []
        while row is not None and row in parts:
            parent, part = parts[row]
            out.append(part)
            row = parent
        return "/".join(reversed(out))

    tags = {}
    for m, t in con.execute("select tm.manifest, t.tag from tags_map tm join tags t on t.rowid = tm.tag"):
        tags.setdefault(m, []).append(t)
    cmds = {}
    for m, c in con.execute("select cm.manifest, c.command from commands_map cm join commands c on c.rowid = cm.command"):
        cmds.setdefault(m, []).append(c)
    pubs = {}
    for m, p in con.execute("select pm.manifest, p.norm_publisher from norm_publishers_map pm join norm_publishers p on p.rowid = pm.norm_publisher"):
        pubs[m] = p
    best = {}
    sql = ("select m.rowid, i.id, n.name, mo.moniker, v.version, m.pathpart from manifest m "
           "join ids i on i.rowid = m.id join names n on n.rowid = m.name join versions v on v.rowid = m.version "
           "left join monikers mo on mo.rowid = m.moniker")
    for rowid, pid, name, moniker, version, pathpart in con.execute(sql):
        key = version_key(version)
        if pid not in best or key > best[pid][0]:
            best[pid] = (key, rowid, name, moniker, version, pathpart)
    out = []
    for pid in sorted(best, key=str.lower):
        _, rowid, name, moniker, version, pathpart = best[pid]
        out.append({"id": pid, "name": name, "moniker": moniker or "", "version": version, "path": path_of(pathpart),
                    "tags": sorted(tags.get(rowid, [])), "commands": sorted(cmds.get(rowid, [])), "publisher": pubs.get(rowid, "")})
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
    print(len(out))


main(sys.argv[1], sys.argv[2])
