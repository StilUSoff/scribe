import XCTest
@testable import ScribeCore

final class GlossaryTests: XCTestCase {
    let glossary = Glossary("""
    # комментарий
    Slack = слак, слаке, слаг, Slag
    TikTok = тик ток
    QA = куа, КЮА
    оргструктура = оркеструктура, орг структура
    Мария, релиз, хотфикс
    """)

    func testParsing() {
        XCTAssertEqual(glossary.terms, ["Slack", "TikTok", "QA", "оргструктура", "Мария", "релиз", "хотфикс"])
    }

    func testReplacesWholeWordsOnly() {
        XCTAssertEqual(glossary.apply(to: "Напиши в слаке, а не в слаг-каналы."), "Напиши в Slack, а не в Slack-каналы.")
        XCTAssertEqual(glossary.apply(to: "задачи доходили до КЮА-отдела"), "задачи доходили до QA-отдела")
        XCTAssertEqual(glossary.apply(to: "Куа, привет"), "QA, привет")                // регистр не важен
        XCTAssertEqual(glossary.apply(to: "слаково и слакер"), "слаково и слакер")      // часть слова не трогаем
        XCTAssertEqual(glossary.apply(to: "куача"), "куача")
    }

    func testMultiwordVariants() {
        XCTAssertEqual(glossary.apply(to: "залили в тик  ток ролик"), "залили в TikTok ролик")
        XCTAssertEqual(glossary.apply(to: "открой орг структура и оркеструктура"), "открой оргструктура и оргструктура")
    }

    func testWildcardEndings() {
        let g = Glossary("""
        ASO-шник* = осошник*
        Slack = слак*
        оргструктур* = орг структур*
        """)
        XCTAssertEqual(g.apply(to: "спроси осошников и осошникам"), "спроси ASO-шников и ASO-шникам")
        XCTAssertEqual(g.apply(to: "в слаке и слаку"), "в Slack и Slack")              // термин без «*» — целиком
        XCTAssertEqual(g.apply(to: "Орг структуре нужен"), "Оргструктуре нужен")
        XCTAssertEqual(g.apply(to: "кислак"), "кислак")                                 // не с начала слова — не трогаем
    }

    func testCaseFixOnlyForCapitalizedTerms() {
        let g = Glossary("Мария, Петров, релиз")
        XCTAssertEqual(g.apply(to: "мария и петров. Релиз завтра."), "Мария и Петров. Релиз завтра.")
    }

    func testDefaultGlossary() {
        let d = Glossary(Glossary.defaultText)
        XCTAssertGreaterThan(d.terms.count, 25)
        XCTAssertTrue(d.terms.contains("Slack"))
        XCTAssertEqual(d.apply(to: "Иван сказал, что в Асане всё есть"), "Иван сказал, что в Asana всё есть")
        XCTAssertEqual(d.apply(to: "Это кейс про гео и рои."), "Это кейс про гео и рои.")  // неоднозначные слова не трогаем
        XCTAssertEqual(d.apply(to: "в орг структуре и оркеструктуру"), "в оргструктуре и оргструктуру")
        XCTAssertEqual(d.apply(to: "он написал в слак"), "он написал в Slack")
        XCTAssertEqual(d.apply(to: "Орг структура готова. Спроси осошников."), "Оргструктура готова. Спроси ASO-шников.")
        XCTAssertEqual(d.apply(to: "под СЕО идут отделы"), "под СЕО идут отделы")  // CEO или SEO — не угадываем
    }
}
