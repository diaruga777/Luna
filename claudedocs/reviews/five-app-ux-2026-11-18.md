# Luna UX audit, 18 November 2026

| App | Finding | Change |
| --- | --- | --- |
| Reader | Reopening a long text article could lay out the full article before showing the saved passage. Import review also reported success before import began. | Render enough text to restore the saved viewport, then fill in the rest. Describe what will be imported before confirmation. Shorten Safari setup and settings copy, and clear legacy shortcut evidence on onboarding reset. |
| Music | Empty podcast views repeated their headings. The collection’s fixed-height empty state could crowd longer instructions. Release builds could skip Mac setup. | Give the active filter a specific empty state, let the footer grow with its text, and restore Mac setup with the existing Not Now action. |
| Writer | The welcome document and empty library views repeated obvious actions. A storage failure on launch could leave a blank view. | Keep the spacebar gesture and Markdown file location in the welcome document. Trim repeated prompts, show a retry action on storage failure and honor Reduce Motion in the note and typewriter animations. |
| Keyboard | The home banner pushed setup lower on small phones. Quest instructions had a fixed text area above the editor and keyboard. Launch also waited for a file cleanup. | Shorten the setup screen, give long lessons their own scroll area and run abandoned-media cleanup on a background queue. |
| Vault | The Release app stopped at an identity error before reaching the pairing field. Its disconnected, search and transfer views also repeated actions or status. | Link the native transport functions directly so the Release linker retains them. Show the Mac pairing field on first launch, provide a retry action for initialization failures and shorten status messages. |

## Verification

Built all five apps in Release. Inspected first-launch and returning screens on iOS 26.2 simulators, including Keyboard Quest at an accessibility text size on iPhone SE. Compared the restored Reader passage before and after the rendering change. The Reader completion badge and Writer’s custom editor effects now follow Reduce Motion. Existing onboarding choreography retains its two beats and stationary text anchor.

| Focused simulator tests | Passed |
| --- | ---: |
| Reader rendering, onboarding, import, settings and strings | 91 |
| Music routing, queue, collection layout and playlist selection | 18 |
| Writer library, document lists and editor focus | 46 |
| Keyboard gestures, paste and compact search | 3 |
| Vault visual flows | 18 |

The paired-Mac transfer test was skipped because it requires a configured live Mac and test file. Physical-device animation frame times, iPad layouts and hardware launch times were outside the simulator measurements. The repository-wide strings check still reports 115 missing entries and four unused entries, down from 116 and five before the audit.

On an iPhone 17 Pro simulator with 100 saved articles of 18,577 words each, Reader’s mean time to its first responsive frame fell from **1.358 s to 1.211 s** across ten cold-process launches per build. The saved passage stayed in place when the rest of the article arrived. [Benchmark procedure and results](../launch-measurement.md)
