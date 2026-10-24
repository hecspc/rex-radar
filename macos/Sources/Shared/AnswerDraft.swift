import SwiftUI

/// What you've picked so far (an ObservableObject: the Mac target avoids SwiftUI's macros).
@MainActor
final class AnswerDraft: ObservableObject {
  let questions: PendingQuestions
  @Published var picks: [Set<Int>]
  @Published var texts: [String]
  @Published var sending = false
  @Published var error: String?

  init(_ questions: PendingQuestions) {
    self.questions = questions
    picks = Array(repeating: [], count: questions.questions.count)
    texts = Array(repeating: "", count: questions.questions.count)
  }

  func toggle(_ q: Int, _ option: Int) {
    if questions.questions[q].isMulti {
      if picks[q].contains(option) { picks[q].remove(option) } else { picks[q].insert(option) }
    } else {
      picks[q] = [option]
      texts[q] = ""
    }
  }

  /// One answer per question, or nil while one is still missing.
  var answers: [QuestionAnswer]? {
    var result: [QuestionAnswer] = []
    for (i, q) in questions.questions.enumerated() {
      let text = texts[i].trimmingCharacters(in: .whitespaces)
      if !q.isMulti, !text.isEmpty {
        result.append(.text(text))
      } else if q.isMulti {
        result.append(.options(Array(picks[i])))
      } else if let pick = picks[i].first {
        result.append(.option(pick))
      } else {
        return nil
      }
    }
    return result
  }
}
