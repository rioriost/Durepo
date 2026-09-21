# App Store Review Preflight

- App / platform: Durepo / macOS
- Version / build: 1.1.2 / 8
- Submission type: update
- Guidelines checked: [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), retrieved 2026-09-21
- Readiness: **NOT READY**
- Counts: **BLOCKER 1 / WARNING 1 / MANUAL 4 / PASS 5 / NOT APPLICABLE 6** (finding groups listed below)

## Actionable findings

### B1 — BLOCKER: Build processing and release association are incomplete

Xcode Organizer successfully uploaded Durepo 1.1.2 (8) on 2026-09-21 at 12:21 JST. App Store Connect independently shows that upload as Processing. Wait for processing and select exactly 1.1.2 (8) for the release draft. The local archive remains development-signed; the distribution-signed package has not been separately inspected. Earlier command-line export failures (`No Accounts` and missing distribution identities) did not establish that the Xcode GUI was signed out; its registered account was visible and the GUI upload succeeded without account or manual certificate changes.

Evidence: `build/release-1.1.2/archive.log`, `export.log`, archive signature, Xcode Organizer upload completion, live TestFlight upload row. Requirements: [Guideline 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness); workflow: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

### W1 — WARNING: Store screenshots still show the previous interface

The new draft inherited four July 17 screenshots in each of English and Japanese. The repository/snapshot layouts and Settings changed. Replace them with actual screenshots of the final build before submission; do not use the incomplete offscreen renderings created during development.

Evidence: live draft media filenames and source diff. Source: [Guideline 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

### M1 — MANUAL: Signed-app runtime qualification remains incomplete

Verify launch, the three settings tabs, keyboard commands, menu actions, privacy/support links, text truncation, and accessibility. Verify the signed helper and a snapshot/restore cycle on disposable data. Native Computer Use returned `Sky Computer Use native pipe closed before response` again during this preparation, while browser access worked. The previous partial NSHostingView captures and passing core tests do not establish runtime/UI readiness. Minimum macOS 26 behavior and VoiceOver are unverified.

Source: [Guidelines 2.1 and 2.4.5](https://developer.apple.com/app-store/review/guidelines/#performance).

### M2 — MANUAL: Review contact completeness

The browser accessibility representation exposes existing first/last-name values but no phone/email values in the review section. This is not sufficient to distinguish absent values from UI masking. No contact fields were changed. Confirm the retained phone/email in App Store Connect before submission; do not invent values.

Source: [Before You Submit and Guideline 1.5](https://developer.apple.com/app-store/review/guidelines/#before-you-submit).

### M3 — MANUAL: Rights and account agreements

App Information declares no third-party content and uses Apple's standard EULA. Local MIT and third-party notices were reviewed as inventory evidence, not proof of all icon/content rights. Developer verification of rights and account-level agreements remains outside the technical evidence collected here. Pricing, tax, banking, and legal declarations were not changed.

Source: [Guideline 5.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property).

### M4 — MANUAL: EU distribution restriction

Pricing and Availability currently shows 148 available territories and 27 unavailable territories; the expanded unavailable list is the EU27. App Information says the developer has identified as a trader. The exact cause of the restriction was not established; do not equate a trader declaration with completed verification. Confirm whether the existing region restriction is intended or resolve the account's compliance status before promising EU availability.

Sources: [Guideline 5](https://developer.apple.com/app-store/review/guidelines/#legal), [Apple DSA requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).

## Confirmed checks

| ID | Status | Evidence |
| --- | --- | --- |
| P1 | PASS | Archive app and helper signatures verify; Sandbox and existing App Group preserved; agent, plist, localizations, icons and privacy manifests present. This does not pass distribution signing. |
| P2 | PASS | 60 existing core tests in two suites passed in the GUI task; subsequent changes add links and version metadata only. Release archive compiles both architectures. |
| P3 | PASS | Live App Privacy says no collection and provides the repository privacy-policy URL. App manifests declare no collection/tracking. The added policy link is in Settings and Help; live policy URL resolves. Runtime activation remains M1. |
| P4 | PASS | Live store version 1.1.1 (7) is Ready for Distribution; new draft is 1.1.2 Prepare for Submission; bundle ID is st.rio.Durepo; local candidate is 1.1.2 (8). |
| P5 | PASS | English/Japanese What’s New and promotional text plus updated review notes saved in the draft; both localization files pass plutil; export-compliance plist value remains false for non-exempt encryption. |

## Applicability and coverage

| Family | Status | Evidence / routed conditions |
| --- | --- | --- |
| Safety | PASS / MANUAL | User-selected local repositories, sandboxed helper, no remote content service; support link added. Contact completeness is M2. N1: public UGC/social/moderation not applicable. N2: medical/physical-harm/kids-targeted features absent. |
| Performance | BLOCKER / WARNING / MANUAL | B1 distribution build; W1 screenshots; M1 actual runtime. No demo account/backend needed. Background helper is opt-in through existing SMAppService controls. |
| Business | NOT APPLICABLE / MANUAL | N3: no StoreKit/IAP/subscription/ads/payment UI in source or dependencies. Store pricing table identifies AUTO_FREE/0; no price changes. Account agreements remain M3. |
| Design | PASS / MANUAL | Substantive native snapshot/recovery utility. GUI improvements compiled, but runtime checks remain M1. N4: web wrapper, third-party login, external hardware, generated-content features absent. N5: widgets, keyboard/browser extensions, mini-app host and Apple media/payment services absent. |
| Legal | PASS / MANUAL | Privacy consistency P3; rights M3; regional availability M4. N6: gambling, VPN, MDM, regulated financial/health services and location features absent. No account-creation/deletion flow is needed for this account-free app. |

App Information also shows Developer Tools as primary category, Utilities as secondary, English as primary language, Japanese localization, and 4+ age rating (regional variants displayed). The app's local Launch Services category remains Utilities; these are separate fields and neither was changed for this update.

## Evidence reviewed

- Live App Store Connect: current 1.1.1 version/build; draft 1.1.2 metadata, inherited media, Build, Review Information, Sandbox justification and automatic release mode; App Privacy; App Information/age/content-rights/DSA declaration; Pricing and Availability including EU27 list.
- Source/configuration: AppModel, ContentView, DurepoApp, project.yml, both entitlement files, both privacy manifests, Package.swift, PRIVACY.md, LICENSE and THIRD_PARTY_NOTICES.md.
- Built artifact: `build/Archive/Durepo-1.1.2-8.xcarchive/Products/Applications/Durepo.app`.
- The initial inspection of the unsigned GUI debug build found a signature warning; it is not the release candidate. The subsequent signed-archive inspection and signature checks pass.
- No complete current runtime screenshot, VoiceOver run, distribution package, processed build, or selected release build is available.

## Final gate

B1, W1 and M1–M4 remain open. Release preparation does not establish App Review or publication readiness. The local development-signed archive was inspected; a selected App Store distribution build was not, because none is available for this draft.

**No submission action was performed.** No Add for Review, Submit for Review, release, contract acceptance, certificate revocation, price change or distribution-region change was performed.
