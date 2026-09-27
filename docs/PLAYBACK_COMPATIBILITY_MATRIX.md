# Playback compatibility

Updated September 16, 2026. This is the current acceptance summary; dated entries
in `WINDOWS_PARITY_PROGRESS.md` remain historical implementation evidence.

The target is reliable scene, video and web playback, including authored controls,
interaction, audio and media dependencies. Application wallpapers, creation tools,
elaborate library management, playlists, scheduling and cloud sync are outside this
goal. Existing functionality must be preserved.

There is no Windows reference machine. **Visual fidelity against Windows is
unverified throughout this matrix.** Local rendering and deterministic behavior
tests provide coverage evidence, not an equivalence percentage. Per the September14
user reprioritization, Windows pixel parity is no longer a readiness gate.
Imperceptible differences are acceptable. Prioritize broad functional coverage,
missing main content, broken essential behavior and unusable performance.

| Capability | Affected unique wallpapers / scope | Implemented evidence | Acceptance still needed |
| --- | --- | --- | --- |
| Package loading and stable capture | 421 eligible scenes | Frozen70 whole-corpus checkpoint: 327 pass / 94 declared partial; no unexpected capture failures or skipped layers | Remaining diagnostics, authored behavior, conspicuous content defects and resource acceptance |
| System media textures | 86 declared partials in the frozen70 whole-421 checkpoint | Pass74 revision2 accepted for bounded local cover/palette delivery: 401 tests per configuration, 170 app captures and image overviews, 108 matched snapshots, 56 short resource repeats and two external synthetic manager tests. Legacy preference identity preserved | Live Music/Spotify, consent, remote artwork and Windows semantics remain unverified. Manager tests use synthetic media and an explicit audio stub; system-textures stays partial |
| Script media events | 51 prior failures in pass61; 110 scenes in the media inventory | Pass65 event delivery; pass74 shared player delivery has tested arbitration, stale-response/cancellation and rendered synthetic property/thumbnail markers | Real player and representative authored media behavior remain unverified. Global/browser discovery and the web media bridge remain absent |
| Script execution across OS threads | Shared host; reproduced thread migration and recursion regressions | Pass77 accepted with bounded evidence: QuickJS refreshes stack bounds and respects smaller worker stacks; 438 enabled tests per configuration, repeated debug suites and 67 current app captures pass their checks | No corpus-wide fixed-wallpaper count inferred; existing authored and unsupported API errors remain |
| Dynamic layer creation | 21 direct callers in269 known script-bearing scenes; includes audio bars and text shadows | Pass79 accepted with limits: real creation/cloning, retained references, updates/order/deletion, imported assets, intrinsic sizes and alignment. Final469 enabled tests per configuration,28 required app captures, four authored control snapshots and eight resource repeats pass bounded checks.119 generated bars and two shadows visibly respond. Earlier49 images remain separately labeled supporting coverage | Live audio, full authored UI/persistence, arbitrary model-data creation and broad sustained performance remain unverified. Static occurrence is not21 individually proven repairs; existing missing/opaque content and slow scenes remain |
| Effect and material script access | Three authored caller scenes; one separate editor-only counter | Pass84 accepted for effect name/index lookup, material property/timeline access and existing native binding delivery. Three reproduced script errors removed; six new tests,495 enabled tests per configuration,34 reviewed native captures and an alternating performance follow-up pass bounded checks | Undeclared shader defaults/custom render functions, turntable one-shot animation and active media remain open. Calendar media script still references missing authored layers. [Evidence](../CompatibilitySuite/reports/pass84-effect-access/verification-summary.json) |
| Zero-sized script helpers | 15 scenes / 16 layers in the eligible421-scene metadata audit; five confirmed visible defects | Pass80 locally accepted: explicit zero dimensions stay non-drawing, scripts keep running, and creation/cloning preserves zero. All40 images reviewed; five white squares disappear without a new diagnostic or paired performance regression | Small existing black tile in3544152633 and severe performance issues remain; occurrence is not a count of15 confirmed repairs. [Evidence](../CompatibilitySuite/reports/pass80-visible-content/verification-summary.json) |
| Script property processing | Shared value-script host; four selected performance scenes | Pass81 accepted for bounded optimization: private native snapshots and unchanged-property revisions preserve fresh values, vector behavior, retries and mutation restoration. 482 executed tests per configuration, 40 visual reviews, four authored presets and 16 clean resource captures pass. Severe target3497488774 improves median1.75→4.15 FPS with essentially unchanged memory; three comparison scenes show no material regression | The target remains severely slow. No corpus-wide speedup, sustained resource or full playback acceptance claimed. Historical image cleanup was reconciled with bounded disposable reviews. [Evidence](../CompatibilitySuite/reports/pass81-playback-performance/verification-summary.json) |
| Shared script input overhead | Shared script host;22 installed scenes have at least50 authored properties (potential reach) | Pass91 reuses immutable property/input/common engine snapshots while preserving fresh mutable script values. Final matching-build ABBA improves clock3.99→4.85FPS and Fuji6.22→8.05FPS. Both configurations pass526 executed tests;115 focused checks, fixtures, original drag and28 canaries pass bounded validation with unchanged diagnostics and main content | Both scenes remain too slow. No corpus-wide speedup, sustained acceptance or new fully usable wallpaper count. [Evidence](../CompatibilitySuite/reports/pass91-script-performance/verification-summary.json) |
| Remaining script slowdown | Two original slow scenes; shared host bookkeeping | Pass96 fresh profiles preserve main content and confirm repeated engine copying. A temporary synthetic-only prototype reduces host cost7–8% and is deferred; accepted95r2 sources are unchanged | No real playback improvement claimed. Larger performance repair remains open; pass97 now verifies two original image-control workflows. [Evidence](../CompatibilitySuite/reports/pass96-playback-profile/verification-summary.json) |
| Desktop frame scheduling | Shared scene CVDisplayLink path; original3544152633 exposed unresponsive controls | Pass97 accepts one pending/in-flight frame and stale-callback invalidation. Nine focused checks,533 executed tests/configuration and28 canaries pass. Original controls work through reload/restart; live probe renders22 frames and services20/20 requests | Debug stress probe has a6.96-second frame; pass98 release follow-up has a3.43-second frame and185 frames/20 requests, with later waits below60ms. Smooth startup and sustained resources remain open. [Evidence](../CompatibilitySuite/reports/pass97-authored-image-controls/README.md) |
| Particle attribute construction | Shared sprite/trail rendering; measured on original3544152633 | Pass99 removes36 temporary arrays per particle/frame while preserving authored content. Fresh release desktop ABBA improves21.97→26.31FPS and41.35→17.97ms render time, with effectively equal RSS.534 executed tests/configuration, fixtures,28 canaries and four original images pass bounded checks | Short one-original performance result; no corpus-wide or sustained gain claimed. Startup preparation and severe script workloads remain. [Evidence](../CompatibilitySuite/reports/pass99-particle-inputs/verification-summary.json) |
| Repeated script-source work | Shared value-script host; one severe scene and one comparison scene | Pass82 profiling identifies repeated source transcoding and wrapper allocation. A prototype passes485 enabled tests per configuration and28 canaries, with an11% severe-scene speedup | Prototype deferred after one unexplained missing clock-board capture; eight follow-up images and the canary do not reproduce it. Accepted81 production restored, three lifetime regression tests retained. No new performance gain adopted. [Evidence](../CompatibilitySuite/reports/pass82-runtime-overhead/README.md) |
| Other script APIs and bindings | Frozen70: 35 whole-corpus script-error IDs; pass71 selected 79: 19 → 11 IDs | Color, module preload and sound have bounded local acceptance; pass71 removes 18 sound-error entries across 13 IDs without added diagnostics | Remaining particle/material APIs, layer lookup and authored errors remain; later video transport acceptance is listed below |
| Pointer input | 23 scenes reference world position; two reference left-button state; 102 reference input/events overall | Pass67 world/screen coordinates, button state, per-display mapping and frame history; focused tests pass | Final representative and eight deterministic input captures complete; physical desktop delivery remains open; bounded 2D event acceptance is recorded in pass88 below |
| Authored cursor events | 94 scenes statically declare callbacks; 734 callback nodes, including 683 with omitted interaction flags | Pass88 revision2 accepts 2D image/text click, hover and drag dispatch locally. Three original wallpapers verify logo drag, circle hover and text-clock drag. Both full configurations pass 509 executed tests; 28 canaries retain 22 passes/six existing partials with unchanged diagnostics and no new conspicuous content loss. All 48 final/superseded images reviewed and deleted | Physical desktop delivery, parallax/shake edge alignment, overlap arbitration, perspective/puppet picking and sustained input-active performance remain unverified. Missing-flag defaults are inferred from corpus evidence. Inventory is not 94 verified repairs. [Evidence](../CompatibilitySuite/reports/pass88-cursor-events/verification-summary.json) |
| Cursor events between frames | One original lost-drag failure confirmed in2865822120;94 callback-bearing scenes are potential reach | Pass90 accepts bounded event buffering and event-specific AppKit input. The original burst drag now moves by the expected(-307.2,+172.8), with updates/simulation once per frame. Both full configurations pass520 executed tests;28 canaries retain22 passes/six existing partials with unchanged diagnostics and no new conspicuous content loss. A build-configuration slowdown was repaired and confirmed with fresh alternating measurements | Physical desktop dragging remains unverified after UI-tool targeting failures. Coalesced motion, overflow cancellation, sustained input-active performance and inherited88 picking limits remain open. [Evidence](../CompatibilitySuite/reports/pass90-cursor-transitions/verification-summary.json) |
| Shader pointer and effect targets | Frozen70: 14 fallback IDs; pass72 covers all 13 pointer cases; pass73 validates 149 workshop scenes plus three samples | Pass73 feedback lifetime, effect ownership and swap mapping accepted locally: six GPU tests, 374 executed tests per configuration, 152 app captures and image pairs. Real off-center ripple feedback now survives release; matched all-up old/new pixels are identical | Numerical formats have the bounded pass76 checkpoint below; fit sizing, effect projection, external targets and shadow-map bindings remain open. Hidden/re-enabled effects, resize behavior and distinct-name cross-effect reads lack new direct GPU acceptance; no Windows reference |
| Effect target numerical formats | Static inventory: seven float-target scenes, 37 reduced-channel scenes, 43 combined | Pass76 R3 accepted locally for numerical storage, RGB alpha, mixed-format copies and shader metadata. Metal validation: 19 focused tests and 432 enabled tests per configuration; five existing opt-ins skipped. All 101 canary pairs, 25 replays, eight day/night repeats, four bloom stage captures and 32 longer resource comparisons reviewed. Six metadata probe failures resolved; configured sunset bloom visibly responds | Windows fidelity, fluid cursor response, live controls/persistence, fit/fixed sizing, repeat UVs and scene HDR remain open. Resource samples are limited: scene3119139541 has a 10.1% higher median RSS with overlapping ranges; scene3497488774 remains about 1.6 FPS. Existing script errors and missing/opaque content remain |
| Text opacity with effects | Confirmed in3202712214;170 text-effect scenes,51 with opacity controls are potential reach | Pass93 applies layer opacity once after effects while preserving expanded coverage. Four old-code regression assertions repaired;81 focused tests and527 executed tests per configuration pass. Original startup/faded-intro comparisons and28 canaries retain expected output and diagnostics | Alpha1 custom-shader rectangles, two media-player block scenes, full corpus and Windows behavior remain unverified. Inventory is not a repair count. [Evidence](../CompatibilitySuite/reports/pass93-text-opacity/verification-summary.json) |
| Effect-level media and image bindings |87 scenes /307 bindings preserved by parser audit;83 scenes use media bindings | Pass95 revision2 preserves effect user/system textures, live file choices, inherited slots and authored media placeholders. Original Girl/Cat artwork repaired; current/previous bindings verified in two scenes.85 focused and530 executed tests per configuration pass;28 canaries retain content/diagnostics | One visible cover repair, not87 verified playback repairs. Pass97 verifies two original image property UI/persistence flows; live OS media, sustained resources and Windows fidelity remain open. [Evidence](../CompatibilitySuite/reports/pass95-effect-user-textures-r2/verification-summary.json) |
| Text and fonts | 240 text-bearing scenes | Pass62–64 measured layout, live styles and registered fonts; targeted tests/captures | The apparent invalid digit in 2961625527 is consistent with the authored font: independent Core Text makes 3 resemble 8, and current FrameText matches local time. Historical runtime text and Windows rasterization remain unverified; exact metrics, anchors and perspective rendering remain open |
| Models and lighting | Three direct-model canaries; 25 lighting canaries | Mesh/material/depth and light improvements have targeted tests | Advanced model effects, shadows, cookies, volumetrics and visual references |
| Particles and animation | 323 scenes with instance controls; 201 with control-point features; two confirmed particle transport method-error scenes | Pass75 play/pause/stop/isPlaying accepted locally: 18 focused tests, 419 enabled tests per configuration, 68 app captures, 92 controlled snapshots and 32 short resource repeats. Four errors disappear; authored hold/release emission responds correctly | Windows child/restart/waiting semantics, forced emission, legacy wrappers, remaining operators, cursor-following fidelity and live control UI/persistence remain open |
| Embedded video timing and controls | 40 scenes / 60 statically reachable MP4 TEX payloads; four confirmed method-error scenes | Pass77 accepted for authored transport, seeking, independent clocks and completion callbacks. Six video errors removed across four scenes; main scene restored in 3445534475. All 64 workshop and three sample images reviewed; no new diagnostic failures | Higher memory with active video layers is retained; two 30-second follow-ups settled. Existing silent decoder, dynamic albedo replacement, live controls and Windows timing remain outside this acceptance |
| System audio response | 208 of 421 scene projects declare audio processing | Pass78 candidate adds native system/input/off selection, asynchronous capture lifecycle, bounded stereo FFT and corrected 64-left/64-right bands. Thirteen focused tests and 451 enabled tests per configuration pass; synthetic PCM drives actual scene and web output | Native live capture is not accepted: three retained probes did not reach readiness. TCC reports system-audio permission undetermined for the launching ChatGPT/Codex app. All 28 canary images reviewed, no new diagnostic or main-content failure; four slow-canary repeats found no candidate slowdown. Live source-to-wallpaper delivery and cleanup remain pending; metadata count is not a confirmed failure count |
| Scene sound playback | 280 of 421 scenes / 496 sound nodes; 55 sound scenes in the accepted 79-scene catalog | Pass71 revision4: transport, authored gain, finite completion, bounded CAF fallback and recovery; 367 executed tests per configuration, four enabled control/output probes, 13 method and eight volume-script canaries | Scheduling, long compressed clips, device interruptions, audible quality, UI persistence/restoration and Windows semantics remain unverified; zero-gain short-clip probes do not establish every scene's audio output |
| Video | 45 eligible MP4 wallpapers; 32 at least 4K wide | Pass83 actual VideoRenderer checks pass for all45: decoded frames, pause/resume, loop rollover, muted state and stop cleanup. Fixed retained queued media/player after stop. Four synthetic tests include uninterrupted looping and replacement;92 reviewed video images deleted. A65-second real-video observation shows continued decoded frames and no observed memory growth | Desktop-compositor presentation, audible output, wake/display migration, application-level persistence and broader sustained resources remain unverified. [Evidence](../CompatibilitySuite/reports/pass83-video-playback/README.md) |
| Web | One eligible authored wallpaper; synthetic WebKit cases | Synthetic playback/property tests pass | Authored page has a confirmed syntax error; retain it separately from host failures |
| Authored customization | Scene/web property tests, three published presets and two synthetic desktop projects | Pass85 verifies real production text/toggle/slider/combo UI edits, rendered changes, separate saved values, fresh-process restoration and reset in an isolated host. Nine images reviewed/deleted; production source unchanged | Pass97 adds two original scene-texture workflows: live replacement, independent saved values, fresh-process rendered restoration and reset/reload. Production navigation, color controls, file picker and preset host options remain open. Pass86 addresses two slider crash conditions found by metadata inspection. [Evidence](../CompatibilitySuite/reports/pass85-desktop-controls/verification-summary.json) |
| Authored slider panel stability | Slider metadata in198 of421 scenes; one reversed definition and one equal definition | Pass86 prevents both panel traps, preserves defaults/saved values, and verifies live edits/reset with original definitions in an isolated scene. Seven tests in each configuration (eight cases), both old-code negative regressions, and28 canaries pass bounded checks:22 pass/six existing partials. Eight same-workload old/new repeats did not reproduce two historical timing flags; all38 images reviewed/deleted | Full original-wallpaper controls, authored conditions and other control types remain open. No performance or broad playback repair count inferred. [Evidence](../CompatibilitySuite/reports/pass86-slider-range/verification-summary.json) |

Counts identify observations or inventory scope; they are not counts of newly fixed
wallpapers. Some inventories include inactive packaged scripts. The report sample
counts must not be extrapolated to the whole corpus. Feature prevalence in the
installed corpus is the current reach estimate; Workshop popularity has not been
measured.

The app benchmark's legacy `cpu_avg_ms` / `cpu_p95_ms` fields measure render
wall time, including the offscreen GPU completion wait during captures. They
are not CPU utilization or pure CPU execution time. Preserve the raw fields
in historical reports, but interpret app timing comparisons with this limit.

## Priorities and validation ownership

1. Repair shared causes of crashes, blank output, missing main content and unusable performance, ranked by confirmed severity and affected unique wallpapers. Use feature prevalence in the installed corpus as a reach estimate; public Workshop popularity has not been measured. Pass80 removes five conspicuous white tiles. Pass90 closes the lost-drag fix and repairs an unoptimized dependency build;91 improves shared script overhead. Pass93 repairs the text-opacity failure isolated in3202712214. Media-player blocks in3404476532 and3544152633 remain undiagnosed. Boat3229704729 renders with centered input; its water-only capture was caused by authored steering toward absent cursor input.
2. Establish essential interaction, playback and authored controls. Pass88 verifies three original drag/hover behaviors; pass90 fixes the loss of a complete original drag between frames. Physical desktop dragging remains unverified after UI-tool targeting failures. Verify representative original-workshop defaults, live changes and persistence/restoration where missing behavior blocks use. Pass83 covers45 videos at renderer level;85 covers synthetic scene/web controls;86 prevents reversed/equal slider crashes.
3. Complete widely used audio/media dependencies. Pass78 native system-output capture acceptance remains pending the previously requested macOS consent;208 of421 scene projects declare audio processing. Continue independent playback work while consent is pending, then verify real player delivery.
4. Restore usable performance through changes likely to make a material difference. Accepted81 improves the severe scene from1.75 to4.15 FPS;91 records a fresh matching-build improvement from3.99 to4.85FPS and Fuji6.22 to8.05FPS. Both remain too slow. Pass97 prevents display-link queue growth. Pass98 separates debug overhead from a3.43-second release startup frame and identifies repeated particle attribute allocations in optimized steady rendering. Pass99 removes those allocations and improves measured desktop FPS21.97→26.31, with unchanged authored content. Pass82's smaller experiment was deferred after one unexplained clock-board capture; accepted81 production is restored. Keep its profile and two diagnostic images, and avoid more blind capture repetition or marginal optimizations; target changes with a material usability benefit.
5. Refresh the unresolved functional failure inventory on accepted99 before choosing the next shared repair; old capture labels do not prove current essential behavior. Address remaining noticeable rendering defects by impact. Defer exact pixel matching, minor font differences and target refinements without visible breakage.

The pass77 source remains the app-wide baseline preceding the pending audio78 change: 438 enabled tests per
configuration (five existing opt-ins skipped), 64 workshop scenes and three samples.
All current images and four fresh affected before/after pairs were reviewed. Six
script-error scenes and two fallback scenes remain in this selected catalog. Two
longer resource checks showed stable memory after video startup, with higher
retained memory explicitly accepted. The narrow bottom-edge strip in 3269762902
was reproduced in a fresh pass76 baseline and remains an existing visual defect.
See the [pass77 evidence](../CompatibilitySuite/reports/pass77-video-transport/verification-summary.json).

Pass79 adds bounded local dynamic-layer acceptance on source with78 audio still
pending. Final25 workshop plus three sample captures produce22 passes and six
declared partials; all28 image pairs were reviewed, with no new diagnostic or
main-content failure. Four authored bar/shadow captures and eight alternating
performance checks pass. Repeated debug-option environment reconstruction caused
the initial slowdowns; caching launch options fixed that cost. The unsuccessful
batching experiment was removed. Earlier46 workshop plus three sample images
remain supporting evidence on their original binary, not a final-source whole
corpus run. See the [pass79 evidence](../CompatibilitySuite/reports/pass79-dynamic-layers/verification-summary.json).
The application baseline remains77 pending78 native-audio acceptance.

Pass83 adds bounded standalone-video acceptance: all45 eligible videos pass real
renderer output, pause/resume, rollover and teardown checks. Stopping now clears
queued media and the player-layer reference. Both configurations pass489 enabled
tests (495 registered, six opt-in skips); the28 scene canaries retain22 passes and
six declared partials with no new diagnostics or obvious content failures. All120
video/canary images were reviewed and deleted. The clock board is present in the
current capture; the historical82 discrepancy is not reclassified. Desktop video
presentation, audible quality and broader application lifecycle remain separate
work. See the [pass83 evidence](../CompatibilitySuite/reports/pass83-video-playback/verification-summary.json).

The pass76 R3 checkpoint retains its 432 enabled tests per configuration and 101
selected app captures. Its broader sweep remains paused after 93 additional
workshop captures: 191 unique workshop scenes on R3 including 98 reused, plus
three samples. Forty new captures and 24 follow-ups were reviewed; 53 newer
captures are preserved as capture/diagnostic evidence, with 230 remaining.
This is not a completed sweep.
No new capture failures, script errors, renderer fallbacks or skipped layers were
reported in those93. Run focused behavior tests and required representative
canaries for each fix; resume broad sweeps at functional integration milestones.

Readiness requires stable output, essential animation/interaction/audio/media,
working authored controls, no conspicuous content loss and usable performance.
Keep fidelity marked unverified without references, but do not block readiness on
missing Windows references or imperceptible differences. Repeat resource checks
when there is a sustained-growth or usability concern, not for small noisy deltas.
Historical strict-parity reports and frozen evidence remain unchanged.

Astra owns integration, acceptance, app/GPU work and performance measurement on the
single test machine. At most two Terra workers may perform bounded independent
work. Do not accumulate more than two implementation changes awaiting validation.

The inactive pass62–66 schedules are retired; their partial results are preserved
and remain historical. The replacement plan and coverage membership are recorded
in [lead-plan.json](../CompatibilitySuite/reports/validation-reconciliation/lead-plan.json).
The current representative catalog includes the required workshop, model, lighting,
text and particle canaries plus relevant script/font and input cases. Run the three
local sample scenes separately. A retired schedule is not a completed result.

See [triage.md](../CompatibilitySuite/reports/validation-reconciliation/triage.md)
for historical failure groups and exact release/debug provenance.
[API failure sites](../CompatibilitySuite/reports/validation-reconciliation/api-failure-sites.md)
map the 22 generic method-error fixtures to concrete capabilities and retain ambiguous
authored/helper cases separately. Embedded-video timing/residency and the corrected color helpers have bounded
local acceptance recorded in pass68 and pass69 revision1 reports. Module preload
has bounded local acceptance recorded in pass70; its whole-421 capture sweep is complete.
Sound acceptance and exact revision4 provenance are recorded in
[pass71 verification](../CompatibilitySuite/reports/pass71-sound-playback/verification-summary.json).
The pass71 selected 79 scenes and frozen70 remaining 342 scenes must not be
presented as a fresh whole-corpus validation of one candidate.
The same limit applies to pass72's selected 74 workshop scenes. Its exact
provenance, mixed baselines and acceptance limits are recorded in
[pass72 verification](../CompatibilitySuite/reports/pass72-pointer-state/verification-summary.json).
Pass73's 149 workshop scenes and three samples are a separate selected-corpus
checkpoint, with 74 accepted72, three accepted71 revision4 and 72 Frozen70 workshop
baselines. The other 272 workshop scenes have not been rerun on pass73. Exact
provenance, controlled comparisons and limits are in
[pass73 verification](../CompatibilitySuite/reports/pass73-effect-feedback/verification-summary.json).

Pass74 uses 138 accepted73 and 29 frozen70 workshop baselines, plus three accepted73 samples. Its other 254 workshop scenes have not been rerun on pass74. Four removed script-error entries are all relative to frozen70 and are not attributed to pass74. Existing opaque regions remain separate from regression acceptance. Pass92 later explains the boat water-only capture through absent cursor input; centered-input captures retain the model, without establishing full model fidelity. The apparent clock digit is now attributed provisionally to the authored font by the pass76 diagnostic. See the [pass74 evidence](../CompatibilitySuite/reports/pass74-shared-media/verification-summary.json) for exact binary/source hashes, manager-harness substitutions and all limits.

Pass75 compares every selected scene/sample against accepted74, including three newly captured old74 baselines. Its other 356 workshop scenes have not been rerun. The two authored input checks load derived mousecursor=1 project settings; they do not establish live UI delivery or persistence/restoration. Matched timing repeats remove the initial threshold flags, but their five-second duration does not establish sustained performance. See the [pass75 evidence](../CompatibilitySuite/reports/pass75-particle-transport/verification-summary.json) for exact provenance and remaining failures.

## Release acceptance

- No unexplained crashes, missing layers, unintended blank frames or significant
  performance/resource regressions in the defined representative corpus.
- Authored settings work from defaults through live edits, persistence and restart.
- Required script, cursor, audio and media behavior is verified for each selected
  feature case, independently of screenshot success.
- Visual comparisons identify inputs, timing, settings, reference provenance and
  justified nondeterministic tolerances. Missing Windows evidence stays explicit.
- Every result names the exact source state and executable tested. Implemented,
  tested locally, and verified against Windows remain distinct states.

These criteria are not yet satisfied. The overall playback goal remains unfinished.
