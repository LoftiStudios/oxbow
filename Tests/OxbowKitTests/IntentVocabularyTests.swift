import AppIntents
import Testing
@testable import OxbowKit

@Suite("Intent vocabulary")
struct IntentVocabularyTests {

  /// AppEnum case IDs are persisted in users' shortcuts. Renaming requires compatibility
  /// handling, not just changing these expected literals.
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

  /// Shortcuts and Settings must share quality-cap wording.
  @Test func theQualityCapReusesItsOwnLabel() {
    for cap in QualityCap.allCases {
      #expect(
        QualityCap.caseDisplayRepresentations[cap]?.title == LocalizedStringResource(
          stringLiteral: cap.label))
    }
  }
}
