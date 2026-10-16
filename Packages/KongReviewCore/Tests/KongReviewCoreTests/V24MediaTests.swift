import XCTest
@testable import KongReviewCore

final class V24MediaTests: XCTestCase {
    func testFindsAllSupportedReferenceFormsAndDecodedNames() {
        let text = #"<img src="a&amp;b.png"><img src="a&#32;b.png"><audio src='voice.mp3'></audio><img src=bare.png> [sound:s.mp3] ![图](plain.png) ![图](kr-media://media/图%20片.png)"#
        let refs = AnkiPackage.mediaReferences(in: text)
        for name in ["a&b.png", "a b.png", "voice.mp3", "bare.png", "s.mp3", "plain.png", "图 片.png"] {
            XCTAssertTrue(refs.contains(name), name)
        }
    }

    func testRewritesReferencesOnceWithoutChangingBodyText() {
        let text = #"a.png <img src="a.png"><img src='b.png'> [sound:a.png] ![图](a.png) ![图](kr-media://media/a.png)"#
        let updated = AnkiPackage.replacingMediaReferences(in: text, names: ["a.png": "b.png", "b.png": "c.png"])
        XCTAssertEqual(updated, #"a.png <img src="b.png"><img src='c.png'> [sound:b.png] ![图](b.png) ![图](kr-media://media/b.png)"#)
    }

    func testRewritesEncodedAndEscapedNamesSafely() {
        let text = #"<img src="a%20b.png"><img src='a&amp;b.png'> ![图](kr-media://media/a%20b.png)"#
        let updated = AnkiPackage.replacingMediaReferences(in: text, names: ["a b.png": "新 图.png", "a&b.png": "新&图.png"])
        XCTAssertTrue(updated.contains(#"src="%E6%96%B0%20%E5%9B%BE.png""#))
        XCTAssertTrue(updated.contains("src='新&amp;图.png'"))
        XCTAssertTrue(updated.contains("kr-media://media/%E6%96%B0%20%E5%9B%BE.png"))
        XCTAssertEqual(AnkiPackage.replacingMediaReferences(in: text, names: [:]), text)
    }
}
