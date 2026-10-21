# Luna Code agent tools

The CLI and stdio MCP use the Apps catalog in the existing Luna Mac companion.
They do not start another Mac app or expose an unauthenticated network server.

Run `python3 scripts/bootstrap_code_refresh.py` from the durable Luna checkout.
Start the correctly signed Luna Mac build, then use `bin/luna-code status` and
`bin/luna-code targets`. `bin/luna-code mcp` serves stdio JSON-RPC.

The local socket is owner-only at
`~/Library/Application Support/Luna Vault/Code/Catalog/control.sock`.
`LUNA_CODE_HOME` overrides this catalog directory for isolated tests/clients;
the running Mac service must use that same directory. `LUNA_CODE_CHECKOUT`
selects the source checkout for a plugin launcher. Bootstrap records its checkout
in `installation.json`; rerun after moving it.

The tool inventory covers status, devices, target registration/removal, builds,
schedules, logs/cancel and GitHub search/inspection/import. Registration requires
explicit source trust and a runnable shared iOS app scheme. Builds use committed
revisions in detached checkouts. Free-account Mac schedules default to 144 hours.
Their success still means confirmed installation rather than compilation.

`python3 scripts/package_code_plugin.py codex /absolute/new/output` produces a
host-specific plugin directory; `cursor` and `claude` are also supported. Existing
output paths are rejected. Install/register through that host's normal workflow;
the repository does not overwrite unrelated agent configuration automatically.

Phone-side refresh is a separate path in the Refresh tab. Apple credentials,
phone pairing records and private signing keys are never MCP parameters.
See [local refresh](code-local-refresh.md) for setup and verification limits.
