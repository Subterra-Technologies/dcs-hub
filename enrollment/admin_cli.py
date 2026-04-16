from __future__ import annotations

import typer

app = typer.Typer(help="subterra-wg-hub admin CLI", no_args_is_help=True)


@app.command("add-school")
def add_school(slug: str, display_name: str, contact_email: str = "") -> None:
    raise NotImplementedError


@app.command("issue-token")
def issue_token(school_slug: str, valid_days: int = 14) -> None:
    raise NotImplementedError


@app.command("list-pending")
def list_pending() -> None:
    raise NotImplementedError


@app.command("approve")
def approve(serial: str) -> None:
    raise NotImplementedError


@app.command("revoke")
def revoke(serial: str) -> None:
    raise NotImplementedError


@app.command("handshakes")
def handshakes() -> None:
    raise NotImplementedError


if __name__ == "__main__":
    app()
