[**Home**](../../../README.md) | [**Session Host Replacer**](README.md) | [**Add-Ons**](../../../docs/add-ons.md)

# Session Host Replacer Flow Diagrams

These diagrams describe one timer invocation. A replacement cycle can span multiple invocations while deployments complete, users drain, or safety checks block further work.

## Shared Evaluation

Both replacement modes begin with the same inventory, image, planning, and validation steps.

```mermaid
flowchart TD
    A[Timer invocation] --> B["Load settings and<br/>deployment state"]
    B --> C["Get latest<br/>image version"]
    C --> D["Inventory session hosts<br/>and active deployments"]
    D --> E["Evaluate enabled scaling plan<br/>and active schedule"]
    E --> F["Build replacement<br/>plan"]
    F --> G{"Any outdated hosts<br/>or pending work?"}
    G -- No --> H["Validate healthy<br/>latest-image hosts"]
    H --> I["Write exact-image<br/>validation tag"]
    I --> J["Update status<br/>and finish"]
    G -- Yes --> K["Evaluate latest-image<br/>host readiness"]
    K --> L{Replacement mode}
    L -- SideBySide --> SBS[SideBySide flow]
    L -- DeleteFirst --> DF[DeleteFirst flow]
```

Exact-image evidence is written whenever a latest-image host has AVD status `Available` and no failed AVD health checks. Drain mode does not prevent evidence from being written.

Readiness then treats a latest-image host as either:

- Online ready: health validated and accepting new sessions.
- Scalable standby: exact-image evidence exists, the VM is stopped or deallocated, AVD status is `Shutdown`, no administrator scaling exclusion applies, and an enabled scaling plan can start it.

Without an enabled, evaluable scaling plan, all latest-image hosts must be online ready. With a scaling plan, at least one must be online ready unless the active target is exactly `0%`.

## SideBySide

SideBySide creates replacement capacity before it removes old capacity. The pool can temporarily grow to twice its target size.

```mermaid
flowchart TD
    A["Receive shared<br/>replacement plan"] --> B{"Deployment already<br/>running?"}
    B -- Yes --> C["Wait for deployment<br/>completion"]
    C --> Z["Finish this invocation<br/>and retry later"]
    B -- No --> D{"New hosts needed and<br/>buffer available?"}
    D -- Yes --> E["Apply progressive<br/>batch limit"]
    E --> F["Deploy latest-image hosts<br/>with new names"]
    F --> G["Save deployment<br/>state"]
    G --> Z
    D -- No --> H{Latest-image hosts ready?}
    H -- No --> I[Preserve old capacity]
    I --> Z
    H -- Yes --> J{"Old hosts eligible<br/>for removal?"}
    J -- No --> Z
    J -- Yes --> K["Enable drain mode on<br/>selected old hosts"]
    K --> L["Set drain timestamp and<br/>replacer scaling exclusion"]
    L --> M["Notify each active<br/>AVD user session"]
    M --> N{Sessions remain?}
    N -- Yes, within grace period --> Z
    N -- Yes, grace expired --> O["Proceed with<br/>forced removal"]
    N -- No --> O
    O --> P{Shutdown retention enabled?}
    P -- Yes --> Q["Deallocate VM and set<br/>retention timestamp"]
    Q --> R["Delete after<br/>retention expires"]
    P -- No --> S["Remove VM and optional<br/>device records"]
    R --> T["Continue until target fleet<br/>uses latest image"]
    S --> T
    T --> Z
```

SideBySide-specific behavior:

- New hosts are deployed before old hosts are drained or removed.
- Failed readiness preserves the old hosts and waits for a later invocation.
- Shutdown retention is available only in this mode.
- Entra ID or Intune cleanup failures are reported but do not block unrelated replacements because hostnames are not reused.

## DeleteFirst

DeleteFirst removes a capacity-safe batch before deploying replacements. It records hostname and dedicated-host placement data before deletion so the replacement can reuse them.

```mermaid
flowchart TD
    A["Receive shared<br/>replacement plan"] --> B{"Previously deleted hosts<br/>unresolved?"}
    B -- Yes --> C["Block additional<br/>deletions"]
    C --> D["Retry only pending<br/>replacement hosts"]
    D --> E["Deploy using saved names<br/>and placement"]
    E --> Z["Finish this invocation<br/>and verify later"]
    B -- No --> F{"Existing latest-image<br/>hosts ready?"}
    F -- No --> G["Block delete and<br/>deploy cycle"]
    G --> Z
    F -- Yes --> H[Calculate replacement batch]
    H --> I["Apply progressive and<br/>maximum deletion limits"]
    I --> J["Apply whole-pool<br/>capacity floor"]
    J --> K{Any hosts safe to remove?}
    K -- No --> Z
    K -- Yes --> L["Save hostname and<br/>placement mapping"]
    L --> M["Enable drain mode on<br/>selected old hosts"]
    M --> N["Set drain timestamp and<br/>replacer scaling exclusion"]
    N --> O["Notify each active<br/>AVD user session"]
    O --> P{Sessions remain?}
    P -- Yes, within grace period --> Z
    P -- No or grace expired --> Q["Delete VM and required<br/>device records"]
    Q --> R{"Deletion and cleanup<br/>verified?"}
    R -- No --> S["Block deployment to prevent<br/>hostname conflict"]
    S --> Z
    R -- Yes --> T[Deploy latest-image hosts]
    T --> U["Reuse deleted names and<br/>dedicated-host placement"]
    U --> V["Save pending<br/>deployment state"]
    V --> Z
```

DeleteFirst-specific behavior:

- The effective whole-pool capacity floor uses the configured minimum during `RampUp` and `Peak`, and the active scaling-plan target during `RampDown` and `OffPeak`.
- An active `0%` scaling target permits a zero-host floor during the applicable off-hours phase.
- `MaxDeletionsPerCycle` remains an independent emergency brake.
- New deletions stop while a previously deleted host is not registered.
- Required Entra ID or Intune cleanup is blocking because stale records can prevent hostname reuse.
- Shutdown retention is always disabled.

## Drain Notification

The user message is sent when the replacer first puts a selected host into drain mode, not when the host merely appears in a plan. Every active AVD session found on that host receives the configured maintenance message. A host already in drain mode with a drain timestamp is not notified again on every timer invocation.
