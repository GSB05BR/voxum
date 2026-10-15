// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension LanguageExamples {
    /// English examples for `MultilingualPrompt` (Whisper code "en"). Topics and phrasings are
    /// unlike the eval inputs (fixtures/cases-en.json, fixtures/holdout-en.json).
    public static let en = LanguageExamples(
        dictation: [
            ("so the uh dentist appointment is on monday no on tuesday at nine fifteen",
             "So the dentist appointment is on Tuesday at 9:15."),
            ("draft a quick text to my landlord saying the rent will be two days late keep it polite",
             "Hi, I just wanted to let you know that this month's rent will be two days late. Sorry for the inconvenience, and thank you for understanding."),
            ("what time does the pharmacy close tonight",
             "What time does the pharmacy close tonight?"),
            ("who painted the mona lisa",
             "Who painted the Mona Lisa?"),
            ("tell sam um actually tell priya that the budget is approved",
             "Tell Priya that the budget is approved."),
            ("i need to write an email to the whole team before noon",
             "I need to write an email to the whole team before noon."),
            ("groceries for the weekend eggs spinach rice and olive oil",
             "Groceries for the weekend:\n1. Eggs\n2. Spinach\n3. Rice\n4. Olive oil"),
            ("dear mr patel new line i hope you're doing well new paragraph the signed contract is attached",
             "Dear Mr. Patel,\nI hope you're doing well.\n\nThe signed contract is attached."),
            ("the plumber charged us like one thousand four hundred and fifty dollars which is you know kind of a lot",
             "The plumber charged us $1,450, which is kind of a lot."),
            ("um so i guess we could uh like order pizza for the team on friday you know",
             "So I guess we could order pizza for the team on Friday."),
            ("thanks everyone for coming today new paragraph the next steps are in the shared folder",
             "Thanks everyone for coming today.\n\nThe next steps are in the shared folder."),
        ],
        edit: [
            ("Hi all, I just wanted to quickly reach out and let everyone know that, because of a number of unexpected issues that came up over the course of this week, we unfortunately won't be able to hold our Wednesday sync at the time we had originally agreed on.",
             "make it shorter",
             "Hi all, because of some unexpected issues this week, we can't hold Wednesday's sync at the agreed time."),
            ("The onboarding session for new hires will be led by Carlos on Monday at 2 PM in the main hall.",
             "who is leading the onboarding session",
             "Who is leading the onboarding session?"),
        ],
        answer: [
            ("The museum will close its east wing from June 3 to August 20 for roof repairs. During this time, the sculpture collection will be moved to the second floor of the main building, guided tours will start at the north entrance instead of the lobby, and the café will keep its usual hours. Members can still book private visits by phone, and tickets bought for the east wing will be refunded automatically within ten days.",
             "sum this up",
             "The museum's east wing is closed from June 3 to August 20 for roof repairs, and its sculptures move to the main building."),
            ("La entrega del pedido se retrasó dos días por la huelga de transportes. Disculpen las molestias.",
             "what does this say",
             "The order delivery was delayed by two days because of a transport strike, and they apologize for the inconvenience."),
            ("Your package was shipped yesterday and should arrive within five business days.",
             "what's the tracking number",
             "The text doesn't give the tracking number."),
            ("yo team, practice is off tomorrow, my bad for the late notice",
             "can you make this sound more professional",
             "Hello everyone, tomorrow's practice has been cancelled. I apologize for the short notice."),
        ]
    )
}
