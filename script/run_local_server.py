#!/usr/bin/env python3
"""Start the local reference server without putting its moderator token in argv."""
import argparse
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path,
                        default=Path(__file__).resolve().parent.parent / "server/.build/debug/App")
    parser.add_argument("--token-file", type=Path,
                        default=Path.home() / ".config/platewatch/moderator-token")
    args = parser.parse_args()
    if not args.binary.is_file():
        parser.error("Build the server first: swift build --package-path server")
    environment = os.environ.copy()
    if not environment.get("MODERATOR_TOKEN"):
        try:
            token = args.token_file.read_text().strip()
        except OSError:
            parser.error("Moderator token file is unavailable; configure it outside the repository")
        if not token:
            parser.error("Moderator token file is empty")
        if args.token_file.stat().st_mode & 0o077:
            parser.error("Moderator token file must be accessible only to its owner (chmod 600)")
        environment["MODERATOR_TOKEN"] = token
    environment.setdefault("HOST", "127.0.0.1")
    environment.setdefault("PORT", "8083")
    os.execve(str(args.binary.resolve()), [str(args.binary.resolve()), "serve"], environment)


if __name__ == "__main__":
    main()
