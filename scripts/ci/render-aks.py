"""Prepare release manifests without copying database credentials to artifacts."""
import shutil
import sys
from pathlib import Path

import yaml


def render(source, destination, backend, frontend):
    source, destination = Path(source), Path(destination)
    shutil.copytree(source, destination, ignore=shutil.ignore_patterns("secret.yaml"))
    path = destination / "kustomization.yaml"
    config = yaml.safe_load(path.read_text())
    config["resources"] = [r for r in config["resources"] if r != "secret.yaml"]
    for image in config["images"]:
        reference = {
            "employee-backend-image": backend,
            "employee-frontend-image": frontend,
        }[image["name"]]
        image["newName"], image["newTag"] = reference.rsplit(":", 1)
        image.pop("digest", None)
    path.write_text(yaml.safe_dump(config, sort_keys=False))


if __name__ == "__main__":
    render(*sys.argv[1:])
