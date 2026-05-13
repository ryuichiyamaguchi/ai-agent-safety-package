# AI Safety Workspace Rules

This workspace is managed by AI Safety Package v1.0.4.

- Start agents only through the provided safe gateway or launch scripts.
- Keep real keys, tokens, customer data, and private access files outside this workspace.
- Do not ask an agent to read protected dot files, private access folders, or files outside the workspace.
- Do not bypass approval or sandbox settings.
- Run the doctor script after CLI updates and before important work.

Allowed working area: this workspace only.
Default network behavior: shell network is blocked; WebFetch is allow-listed.
