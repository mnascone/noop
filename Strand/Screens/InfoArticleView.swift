import SwiftUI
import StrandDesign

/// A plain explainer page for Settings › Information: a title, then short headed paragraphs.
struct InfoArticleView: View {
    struct Part: Identifiable {
        let heading: String
        let body: String
        var id: String { heading }
    }

    let title: String
    let subtitle: String
    let parts: [Part]

    var body: some View {
        ScreenScaffold(title: "\(title)", subtitle: "\(subtitle)") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                ForEach(parts) { p in
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                            Text(p.heading)
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(p.body)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    static var stress: InfoArticleView {
        InfoArticleView(
            title: String(localized: "Stress"),
            subtitle: String(localized: "How the stress ring and the Stress screen are worked out"),
            parts: [
                Part(heading: String(localized: "One reading, always labelled"),
                     body: String(localized: "The Today ring, the Stress screen and the Lock Screen show the same reading, and say where it came from. Live, Measured with a time, the latest scored hour, or This morning's score. Only beats arriving now are ever called live.")),
                Part(heading: String(localized: "Live and Measure now"),
                     body: String(localized: "While your strap streams heart rate, the last two minutes' mean heart rate and beat-to-beat variability (RMSSD) are scored exactly like an hour of today's timeline, against today's calm hours, so the ring and the timeline agree. Before today has a scored hour, it uses about 65% of your usual overnight HRV as the calm reference instead. Measure now streams for a minute and keeps the result for half an hour. While heart rate is up from moving it shows Active, because HRV can't tell stress apart from effort then.")),
                Part(heading: String(localized: "Today's hours"),
                     body: String(localized: "Through the day, stored heart rate is scored hour by hour on the same 0 to 3 scale as the daily number. The ring uses the latest scored hour when it ended within the last two hours.")),
                Part(heading: String(localized: "This morning's score"),
                     body: String(localized: "The daily number compares last night's resting heart rate and HRV with your last 30 days: a higher resting heart rate and lower HRV than usual mean more stress. It's set once a day, so it can read Low while right now reads High, or the other way round: they measure different things. It's the fallback when there's nothing more recent, and it's labelled This morning's score so it never passes as live.")),
                Part(heading: String(localized: "The scale"),
                     body: String(localized: "0 to 100 on the ring is the Stress screen's 0 to 3 scale. Low is under 33 (under 1), Medium under 67 (under 2), High above.")),
            ])
    }

    static var pace: InfoArticleView {
        InfoArticleView(
            title: String(localized: "Pace"),
            subtitle: String(localized: "Whether your load is keeping step with your recovery"),
            parts: [
                Part(heading: String(localized: "What it compares"),
                     body: String(localized: "Your recent Effort and Charge against your own normal. Short term is the last 3 days against the 11 before. Long term is the last 7 days against the 4 weeks before. Once there's enough history the long term counts for 70% of the reading.")),
                Part(heading: String(localized: "How it's worked out"),
                     body: String(localized: "The change in Effort beyond the change in Charge, as log ratios, so 20% more Effort with Charge flat reads the same as Effort flat with Charge down 20%. Stress above your usual adds to the load the way extra Effort does. A difference of about 35% fills the ring.")),
                Part(heading: String(localized: "Reading the ring"),
                     body: String(localized: "It fills out from the top. Left and green means Charge is ahead and there's room to push. Right and red means Effort is outrunning recovery. Near the top is on pace.")),
            ])
    }
}
