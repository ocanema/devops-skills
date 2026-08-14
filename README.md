# devops-agent-skills

Our team's Agent Skills — the internal skills repo that `apm.yml` pulls from.

Each skill lives at `skills/<name>/SKILL.md`. Consumers reference a skill as
`adamgordonbell/devops-agent-skills/skills/<name>` in their `apm.yml`;
APM pins the exact commit in `apm.lock.yaml`, so a skill change ships to
teammates only when they re-run `apm install`.

## Skills

| Skill | What it does |
|---|---|
| `cluster-health` | Read-only health sweep of the current Kubernetes cluster |
| `service-connectivity-triage` | Diagnose a Service that's dark while its pods are green — endpoints, selector mismatches, DNS red herrings |

## Contributing

Treat skills like code: branch, PR, review. The description field is the
trigger — write it so the agent fires the skill on the phrases your team
actually says.
