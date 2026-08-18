# Air-Gapped Review Checklist

- Target cloud and management-workstation connectivity are stated.
- The selected base manifest and customer overlay are both reviewed.
- No `WingetId` is expected to execute inside the air-gapped environment.
- Every external source has an exact filename, destination, and transfer method.
- API-discovered downloads are resolved on a connected system before transfer.
- `downloadLatestMicrosoftContent` is disabled for disconnected image builds.
- AVD Agent and Boot Loader sources are valid for the target cloud or internally hosted.
- Browser and Office administrative templates are bundled when their ADMX-backed path is required.
- No Blue Button instructions are given for Secret or Top Secret.
- The final report distinguishes verified, manually staged, and unresolved dependencies.
