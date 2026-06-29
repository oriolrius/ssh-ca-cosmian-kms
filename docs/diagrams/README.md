# Diagram sources

This directory holds the **editable source** for the four figures embedded in
[`docs/technical-reference.md`](../technical-reference.md). The `.mmd` files are
[Mermaid](https://mermaid.js.org/) text; the PNGs that appear in the document
(and in the generated PDF) are **rendered from these sources in CI** so the
diagrams stay editable and version-controlled rather than living only as binary
images.

> Edit the `.mmd` here, not the PNGs. Then re-render (locally or via CI).

## Files

| Source | Figure | Diagram type | What it shows |
|---|---|---|---|
| `01-verification-decision-chain.mmd` | Figure 1 | flowchart | The 6-step sshd certificate verification decision chain. Each step is a decision node; a `No` branch leads to `REJECT (reason)`, and passing all six leads to `ACCESS GRANTED`. |
| `02-host-cert-flow.mmd` | Figure 2 | sequenceDiagram | Host certificate authentication flow: the server presents a host certificate, the client trusts the Host CA once via `@cert-authority`, and TOFU is eliminated. |
| `03-user-cert-flow.mmd` | Figure 3 | sequenceDiagram | User certificate authentication flow, including the `AuthorizedPrincipalsFile` (`%u`) principal-to-account RBAC indirection. |
| `04-ansible-workflow.mmd` | Figure 4 | sequenceDiagram | Jan-Piet Mens' Ansible host-cert deployment across Controller, SSH Agent, and Target Node (Phase 1 keygen on node, Phase 2 sign on controller via agent/KMS, Phase 3 deploy cert, Phase 4 cleanup). |

## Render locally

The figures are rendered with
[`@mermaid-js/mermaid-cli`](https://github.com/mermaid-js/mermaid-cli) (the
`mmdc` binary). No global install is required if you have Node.js available:

```bash
# Render a single diagram
npx -y @mermaid-js/mermaid-cli \
  -i docs/diagrams/01-verification-decision-chain.mmd \
  -o docs/media/586b6632e399e3ddb431c512d989ea6e43bb9bc2.png

# Render all four at once
for f in docs/diagrams/*.mmd; do
  npx -y @mermaid-js/mermaid-cli -i "$f" -o "${f%.mmd}.png"
done
```

Useful flags: `-t default|neutral|dark|forest` (theme), `-b transparent|white`
(background), `-w 1600` (output width for higher-resolution PNGs).

## How CI maps sources to the document

`docs/technical-reference.md` references the rendered figures by their content-
hashed filenames under `docs/media/`:

| Source `.mmd` | Rendered PNG referenced by the doc |
|---|---|
| `01-verification-decision-chain.mmd` | `docs/media/586b6632e399e3ddb431c512d989ea6e43bb9bc2.png` |
| `02-host-cert-flow.mmd` | `docs/media/12ba1c372e07e979a227ae136a59e2d3eac71cb8.png` |
| `03-user-cert-flow.mmd` | `docs/media/e826eb343e6f75995ac364ba2875e704465b9eb5.png` |
| `04-ansible-workflow.mmd` | `docs/media/b25a3bfe615d49e7ca0ea7c01d38b1e42207ec3d.png` |

When you change a `.mmd`, re-render it to the matching `docs/media/*.png` path
(see the command above) so the document and PDF pick up the update.

## Editing tips

- Keep node/message labels short; use `<br/>` for line breaks (the rest of the
  repo's diagrams follow this convention).
- These diagrams use only mainstream Mermaid syntax (`flowchart`,
  `sequenceDiagram`, `autonumber`, `note`, `alt`/`else`, `classDef`) so they
  render with current `@mermaid-js/mermaid-cli`. Avoid experimental/exotic
  syntax that the CLI may not support.
- Validate a change before committing by rendering it: if `mmdc` errors, the
  syntax is invalid.

---

Licensed MIT (c) 2026 Oriol Rius.
