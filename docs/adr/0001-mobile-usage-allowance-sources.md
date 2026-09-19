# Mobile usage and allowance sources

Status: accepted

The mobile account area uses a single read-only `/m/api/account-usage` projection rather than depending on `dsh-plugin-llm-balance`: the host keeps provider credentials private, queries DeepSeek directly, uses dsh-codex-connect's secret-free Codex usage projection, and resolves OpenCode Go through the DSH credentials service. Sources are independently successful or absent, quota windows are never summed, and the projection is cached only in process for 60 seconds so the phone does not persist provider billing facts.

The phone shows only the active Codex account and the latest successful sources. OAuth login, API-key entry, account switching, and quota alerts remain desktop/provider concerns; this keeps the mobile trust boundary read-only and avoids making a third-party balance plugin a required runtime dependency.
