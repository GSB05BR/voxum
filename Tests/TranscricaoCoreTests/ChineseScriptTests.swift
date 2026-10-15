// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest
@testable import TranscricaoCore

final class ChineseScriptTests: XCTestCase {
    func testTraditionalBecomesSimplified() {
        // The Traditional characters Whisper wrote for Simplified speech in the zh WER clips.
        XCTAssertEqual(ChineseScript.simplified("會議資料發郵件"), "会议资料发邮件")
        XCTAssertEqual(ChineseScript.simplified("请把会议资料发给我"), "请把会议资料发给我")
        XCTAssertEqual(ChineseScript.simplified("Send it to John."), "Send it to John.")
        XCTAssertEqual(ChineseScript.simplified(""), "")
    }

    /// The whole zh WER error (CER 9.4%, 5/53) was Whisper's Traditional script: the raw path fixes it.
    func testTheWhisperClipBecomesTheReference() {
        XCTAssertEqual(ChineseScript.rawForPaste("你能不能把明天會議的資料發到我的郵箱?", language: "zh"),
                       "你能不能把明天会议的资料发到我的邮箱？")
    }

    func testHalfWidthPunctuationAfterChineseBecomesFullWidth() {
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("明天开会, 下午三点?"), "明天开会，下午三点？")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("注意: 不要迟到!"), "注意：不要迟到！")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的.谢谢."), "好的。谢谢。")
    }

    func testOtherPunctuationIsKept() {
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("一共3,000元"), "一共3,000元")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("OK, 好"), "OK, 好")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("第3.5版"), "第3.5版")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("版本v1.2"), "版本v1.2")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("我用Mac, 你呢?"), "我用Mac, 你呢？")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("Hello, world."), "Hello, world.")
    }

    func testEdgeCases() {
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("什么?!"), "什么？！")
        // The Chinese ellipsis, never "。。。".
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的..."), "好的……")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的... 我想想."), "好的……我想想。")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的...?"), "好的……？")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的…, 嗯"), "好的……，嗯")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("嗯…对"), "嗯……对")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("wait... 好"), "wait... 好")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的. OK"), "好的。OK")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("你好, John"), "你好，John")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("网址是 http://例子.中国 , 记住"), "网址是 http://例子.中国 , 记住")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("时间:10:30"), "时间：10:30")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("圆周率是3.14"), "圆周率是3.14")
        XCTAssertEqual(ChineseScript.fullWidthPunctuation("好的.  "), "好的。  ")
    }

    func testRawForPasteOnlyTouchesChinese() {
        XCTAssertEqual(ChineseScript.rawForPaste("會議, 明天?", language: "zh"), "会议，明天？")
        XCTAssertEqual(ChineseScript.rawForPaste("會議, 明天?", language: "zh-Hans"), "会议，明天？")
        XCTAssertEqual(ChineseScript.rawForPaste("會議, 明天?", language: "ja"), "會議, 明天?")
        XCTAssertEqual(ChineseScript.rawForPaste("會議, 明天?", language: nil), "會議, 明天?")
        XCTAssertEqual(ChineseScript.rawForPaste("hi, there?", language: "en"), "hi, there?")
    }
}
