# App Store Review Preflight

- App / platform: Durepo / macOS
- Version / build: 1.1.2 / 8
- Submission type: update
- Guidelines checked: [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), displayed update June 8, 2026; retrieved again 2026-09-21
- Preflight readiness: **READY WITH MANUAL CONFIRMATIONS** (technical submission validation passed; runtime and screenshot limitations remain)
- Final outcome: user confirmed submission with those limitations; **Waiting for Review / 審査待ち**, verified 2026-09-21 at 12:32 JST.
- Counts: **BLOCKER 0 / WARNING 2 / MANUAL 2 / PASS 8 / NOT APPLICABLE 6** (finding groups listed below)

## Actionable findings

### B1 — RESOLVED: Build processed and selected

Xcode Organizer uploaded Durepo 1.1.2 (8) on 2026-09-21 at 12:21 JST. App Store Connect subsequently showed the upload as Complete and build 8 as Ready to Submit. Build 8 was selected, saved, and reverified in version 1.1.2. At 12:30, Add for Review passed and the submission draft listed only macOS 1.1.2 (8), with an enabled Submit for Review button. This is not final submission or approval. The local archive remains development-signed; the distribution-signed package was not separately inspected. Earlier command-line signing errors did not establish that the Xcode GUI was signed out.

Evidence: `build/release-1.1.2/archive.log`, `export.log`, archive signature, Xcode Organizer upload completion, live TestFlight upload row. Requirements: [Guideline 2.1](https://developer.apple.com/app-store/review/guidelines/#app-completeness); workflow: [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/).

### W1 — WARNING: Store screenshots still show the previous interface

The new draft inherited four July 17 screenshots in each of English and Japanese. The repository/snapshot layouts and Settings changed. Replace them with actual screenshots of the final build before submission; do not use the incomplete offscreen renderings created during development.

Evidence: live draft media filenames and source diff. Source: [Guideline 2.3](https://developer.apple.com/app-store/review/guidelines/#accurate-metadata).

### M1 — MANUAL: Signed-app runtime qualification remains incomplete

Verify the three settings tabs, keyboard commands, menu actions, privacy/support links, text truncation, and accessibility. Verify the signed helper and a snapshot/restore cycle on disposable data. Native Computer Use again returned `Sky Computer Use native pipe closed before response` for the exact archived app path during the submission check. A process sample confirms version 1.1.2 (8) running on macOS 27.0 (26A428), with its main thread primarily waiting in the normal event loop; it does not establish successful user interaction. Previous partial NSHostingView captures and passing core tests do not establish runtime/UI readiness. Minimum macOS 26 behavior and VoiceOver are unverified.

Source: [Guidelines 2.1 and 2.4.5](https://developer.apple.com/app-store/review/guidelines/#performance).

### M2 — RESOLVED: Review contact is populated

The actual browser screenshot shows the existing name, phone number, and email populated. Accessibility and DOM-derived empty values did not reflect the rendered fields. No contact fields were changed, and private contact values are not copied into this report. Add for Review passed without a contact validation error.

Source: [Before You Submit and Guideline 1.5](https://developer.apple.com/app-store/review/guidelines/#before-you-submit).

### M3 — MANUAL: Content rights

App Information declares no third-party content and uses Apple's standard EULA. Local MIT and third-party notices were reviewed as inventory evidence, not independent proof of all icon/content rights. Developer verification of those rights remains a manual item. Business shows both Free Apps and Paid Apps agreements as Active; no contract acceptance or legal declaration was performed.

Source: [Guideline 5.2](https://developer.apple.com/app-store/review/guidelines/#intellectual-property).

### W2 (formerly M4) — WARNING: EU distribution restriction and pending DSA review

Pricing and Availability still shows 148 available territories and the EU27 unavailable. App Information has a trader declaration, while Business explicitly shows DSA status In Review, last updated September 15. The pending DSA review is consistent with the regional restriction, but this check does not prove it is the only cause. Add for Review passed. Existing availability is retained; EU availability must not be promised while verification remains pending.

Sources: [Guideline 5](https://developer.apple.com/app-store/review/guidelines/#legal), [Apple DSA requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements).

## Confirmed checks

| ID | Status | Evidence |
| --- | --- | --- |
| P1 | PASS | Archive app and helper signatures verify; Sandbox and existing App Group preserved; agent, plist, localizations, icons and privacy manifests present. This does not pass distribution signing. |
| P2 | PASS | 60 existing core tests in two suites passed in the GUI task; subsequent changes add links and version metadata only. Release archive compiles both architectures. |
| P3 | PASS | Live App Privacy says no collection and provides the repository privacy-policy URL. App manifests declare no collection/tracking. The added policy link is in Settings and Help; live policy URL resolves. Runtime activation remains M1. |
| P4 | PASS | Live store version 1.1.1 (7) is Ready for Distribution; new draft is 1.1.2 Prepare for Submission; bundle ID is st.rio.Durepo; local candidate is 1.1.2 (8). |
| P5 | PASS | English/Japanese What’s New and promotional text plus updated review notes saved in the draft; both localization files pass plutil; export-compliance plist value remains false for non-exempt encryption. |
| P6 | PASS | Upload processed; exactly 1.1.2 (8) selected and saved; Add for Review accepted the version and the submission draft contains only that build. |
| P7 | PASS | Actual rendered review contact fields are populated; no contact edits were needed. |
| P8 | PASS | Free Apps and Paid Apps agreements show Active. Existing free price and 148 available territories retained. DSA review remains W2. |

## Applicability and coverage

| Family | Status | Evidence / routed conditions |
| --- | --- | --- |
| Safety | PASS | User-selected local repositories, sandboxed helper, no remote content service; support link added and contact fields populated. N1: public UGC/social/moderation not applicable. N2: medical/physical-harm/kids-targeted features absent. |
| Performance | PASS / WARNING / MANUAL | Build processed and selected; W1 screenshots; M1 actual runtime. No demo account/backend needed. Background helper is opt-in through existing SMAppService controls. |
| Business | PASS / NOT APPLICABLE | N3: no StoreKit/IAP/subscription/ads/payment UI in source or dependencies. Store pricing table identifies AUTO_FREE/0; no price changes. Agreements Active. |
| Design | PASS / MANUAL | Substantive native snapshot/recovery utility. GUI improvements compiled, but runtime checks remain M1. N4: web wrapper, third-party login, external hardware, generated-content features absent. N5: widgets, keyboard/browser extensions, mini-app host and Apple media/payment services absent. |
| Legal | PASS / WARNING / MANUAL | Privacy consistency P3; rights M3; regional availability W2. N6: gambling, VPN, MDM, regulated financial/health services and location features absent. No account-creation/deletion flow is needed for this account-free app. |

App Information also shows Developer Tools as primary category, Utilities as secondary, English as primary language, Japanese localization, and 4+ age rating (regional variants displayed). The app's local Launch Services category remains Utilities; these are separate fields and neither was changed for this update.

## Evidence reviewed

- Live App Store Connect: current 1.1.1 version/build; draft 1.1.2 metadata, inherited media, Build, Review Information, Sandbox justification and automatic release mode; App Privacy; App Information/age/content-rights/DSA declaration; Pricing and Availability including EU27 list.
- Source/configuration: AppModel, ContentView, DurepoApp, project.yml, both entitlement files, both privacy manifests, Package.swift, PRIVACY.md, LICENSE and THIRD_PARTY_NOTICES.md.
- Built artifact: `build/Archive/Durepo-1.1.2-8.xcarchive/Products/Applications/Durepo.app`.
- The initial inspection of the unsigned GUI debug build found a signature warning; it is not the release candidate. The subsequent signed-archive inspection and signature checks pass.
- Submission recheck: `build/release-1.1.2/preflight-submission.json` confirms the archived version, signature, sandbox entitlements and privacy manifests; no new automated observations. Process sample is an ignored local diagnostic, not UI verification.
- No complete current runtime screenshot, VoiceOver run, or separately inspected distribution package is available. The uploaded build is processed and selected.

## Final gate

W1 (old screenshots), W2 (EU/DSA), M1 (runtime coverage), and M3 (rights) remain open. The selected build identity matches the inspected local archive and Apple completed upload processing. Submission validation does not establish App Review approval or complete runtime qualification.

**Final submission performed after explicit user confirmation.** App Store Connect confirmed one item submitted; the submission detail page shows macOS 1.1.2 (8), Waiting for Review, submitted 2026-09-21 at 12:32 JST. Submission ID: `c7ca5c17-aa46-4ae5-86be-f86a406ffe34`. Submission does not establish approval or publication, and the disclosed preflight limitations remain recorded above. The inherited release mode is automatic after approval. No contract acceptance, certificate revocation, price change or distribution-region change was performed.
