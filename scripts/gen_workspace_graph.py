#!/usr/bin/env python3

import json
import subprocess
from pathlib import Path


def _unique(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def main() -> None:
    repo_root = Path(__file__).resolve().parent.parent
    workspace_dir = repo_root
    output_path = repo_root / "nix" / "workspace_dependency_graph.json"

    proc = subprocess.run(
        ["dart", "pub", "deps", "--json", "-C", str(workspace_dir)],
        check=True,
        capture_output=True,
        text=True,
    )
    deps = json.loads(proc.stdout)

    workspace_root_name = deps["root"]
    roots: dict[str, dict[str, list[str]]] = {}
    packages: dict[str, list[str]] = {}

    for package in deps.get("packages", []):
        name = package["name"]
        kind = package.get("kind")

        main_deps = _unique(list(package.get("directDependencies") or []))
        dev_deps = _unique(list(package.get("devDependencies") or []))
        all_deps = _unique(list(package.get("dependencies") or []))

        if kind == "root":
            packages[name] = main_deps
            if name != workspace_root_name:
                roots[name] = {
                    "main": main_deps,
                    "dev": dev_deps,
                }
        else:
            packages[name] = all_deps

    graph = {
        "version": 1,
        "workspaceRoot": workspace_root_name,
        "roots": {name: roots[name] for name in sorted(roots)},
        "packages": {name: packages[name] for name in sorted(packages)},
    }

    output_path.write_text(json.dumps(graph, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Successfully generated {output_path.relative_to(repo_root)}")


if __name__ == "__main__":
    main()
