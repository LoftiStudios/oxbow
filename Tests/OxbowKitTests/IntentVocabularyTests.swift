import AppIntents
import Testing
@testable import OxbowKit

@Suite("Intent vocabulary")
struct IntentVocabularyTests {

  /// **These strings are storage, in a file this repository cannot see.**
  /// An `AppEnum` case identifier is what Shortcuts persists inside a user's
  /// saved shortcut, so renaming a case silently breaks shortcuts that
  /// already exist on other people's machines — with no error anywhere, the
  /// same failure mode `QualityLadderTests.rawValuesArePersistedAndPinned`
  /// pins the `UserDefaults` raw values against.
  ///
  /// If this fails after a rename: fix the case name, not the test.
  @Test func everyCaseHasADisplayRepresentation() {
    for cap in QualityCap.allCases {
      #expect(QualityCap.caseDisplayRepresentations[cap] != nil, "QualityCap.\(cap)")
    }
    for output in DownloadOutput.allCases {
      #expect(DownloadOutput.caseDisplayRepresentations[output] != nil, "DownloadOutput.\(output)")
    }
    for size in ChatSize.allCases {
      #expect(ChatSize.caseDisplayRepresentations[size] != nil, "ChatSize.\(size)")
    }
  }

  /// The cap's Shortcuts wording and its Settings-window wording are the
  /// same string, from the same property. Two vocabularies for one preference
  /// is the thing `DownloadOutput` living in `OxbowKit` already exists to
  /// prevent (docs/design/settings.md §5).
  @Test func theQualityCapReusesItsOwnLabel() {
    for cap in QualityCap.allCases {
      #expect(
        QualityCap.caseDisplayRepresentations[cap]?.title == LocalizedStringResource(
          stringLiteral: cap.label))
    }
  }
}
