# DSH Mobile Remote

DSH Mobile Remote extends a single user's computer-hosted DeepSeek Harness into a phone remote, including read-only visibility into the balances and quotas of configured model providers.

## Language

**Usage and allowance**:
The mobile account area that groups provider-specific monetary balances and time-window quotas without pretending they share one additive total.
_Avoid_: Balance page, total balance

**Balance**:
A monetary amount that remains available for spending, such as the DeepSeek API CNY balance or finite Codex credits.
_Avoid_: Quota, allowance

**Quota**:
Capacity remaining within a provider-defined time window, represented independently for each window and accompanied by its reset time when known.
_Avoid_: Balance, total balance

**Quota window**:
One independently reset usage period, such as 5 hours, week, or month; valid windows are shown separately and are never summed.
_Avoid_: Billing period, total quota

**Active Codex account**:
The single account currently selected by dsh-codex-connect for subsequent Codex requests; mobile usage visibility follows this account only and identifies it by display name and masked email.
_Avoid_: Mobile account, session account

**Codex credits**:
A monetary Codex balance reported independently from time-window quotas; finite credits remain visible even when quota windows are also present.
_Avoid_: Codex quota, combined balance

**Individual spending limit**:
A Codex workspace member's exact allowance, used amount, and remaining amount; it is separate from both Codex credits and time-window quotas.
_Avoid_: Monthly quota, Codex credits

**Usage source**:
A provider account whose latest balance or quota query succeeds; a source stops being available as soon as its latest query fails and is omitted from the detail view.
_Avoid_: Account, model

**Usage summary**:
The count of currently available usage sources shown in the account area; it never aggregates balances or quota percentages.
_Avoid_: Total balance, combined quota
