# Repo Instructions

## User Interaction Rule

When the user asks for operational setup steps, installation steps, or any multi-step local workflow:

- Give exactly one step at a time.
- Wait for explicit user confirmation before giving the next step.
- Do not bundle multiple setup actions into a single response unless the user explicitly asks for the full list at once.
- If a step has a verification action, include that verification in the same step.
- Default to doing terminal and file actions directly on the user's behalf unless the step requires the user's UI interaction, credentials, or explicit approval.

This rule applies in particular to:
- local environment setup
- Docker setup
- OSRM setup
- service startup / shutdown flows
- deploy or migration workflows
