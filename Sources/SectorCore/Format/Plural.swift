import Foundation

/// Counted nouns: "1 файл", "3 файла", "5 файлов".
///
/// Each form is localized on its own (English maps "файла" and "файлов" to
/// "files"), so callers pass the three Russian forms and get correct output
/// in both languages without a stringsdict per phrase.
public enum Plural {
  public static func format(
    _ n: Int, _ one: String, _ few: String, _ many: String, locale: Locale = .current
  ) -> String {
    "\(n.formatted(.number.locale(locale))) \(word(n, one, few, many, locale: locale))"
  }

  /// Only the noun in the right form.
  public static func word(
    _ n: Int, _ one: String, _ few: String, _ many: String, locale: Locale = .current
  ) -> String {
    let form: String
    if locale.language.languageCode?.identifier == "ru" {
      let mod10 = n % 10
      let mod100 = n % 100
      if mod10 == 1 && mod100 != 11 {
        form = one
      } else if (2...4).contains(mod10) && !(12...14).contains(mod100) {
        form = few
      } else {
        form = many
      }
    } else {
      form = n == 1 ? one : many
    }
    return Bundle.main.localizedString(forKey: form, value: form, table: nil)
  }
}
