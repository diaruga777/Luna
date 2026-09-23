# Vault import and background sync plan

## Outcome

Files selected in Vault, selected from Photos, or sent to the Vault share extension enter one durable FIFO queue. Vault copies each source into its App Group before acknowledging it, stages each item into the existing Syncthing-compatible local-change store, and waits for the paired Mac's index confirmation before marking it complete. Photos go to `Photos/<filename>`; album imports go to `Photos/<album>/<filename>`.

## Implementation

1. Add a small App Group inbox with atomic item publication. The share extension accepts multiple file providers, copies each provider's bytes into the inbox, and reports **queued** only after the copy succeeds. File and Photos pickers use the same inbox.
2. Add one queue runner in the Vault app. It consumes inbox items in order, retains failed/offline items for retry, and uses existing `VaultSyncSession` local changes as the durable transfer state. Reopening the app or a scheduled processing wake resumes pending work.
3. Replace the current background transition that unconditionally stops the Mac connection. For a user-started queue, submit an iOS 26 `BGContinuedProcessingTask` from Vault or its share extension and update its system Live Activity with aggregate file and byte progress. Finish the task when the queue and Mac-confirmed uploads are empty. Handle expiration by preserving pending work and scheduling `BGProcessingTask` retry.
4. Add Photos asset and album selection, export originals without loading entire media into memory, and preserve album hierarchy under `Photos`.
5. Build the Vault app and extension and test queue durability, ordering, collision handling, and Mac confirmation against the loopback sync tests.

## Platform boundary

Apple's iOS 26 SDK permits an extension to submit a continued processing request, and the containing app handles the work. The share extension still cannot reliably open the app itself, so it first publishes the payload to the App Group, then submits a request. If the system rejects or delays that request, Vault resumes the queue when opened or at a scheduled processing wake. iOS can expire or cancel background work, so the queue survives process death and the Live Activity appears only while a continued task is running.
