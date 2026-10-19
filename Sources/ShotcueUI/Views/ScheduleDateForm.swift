import ShotcueCore
import SwiftUI

/// "Zamanla…" in the inspector, the library's selection bar and the quick panel. Quick picks, a calendar for the
/// day, a typed time and a readable summary; a time that is already past cannot be scheduled.
///
/// The graphical picker used to carry both the date and the time with a visible label: in a 320 pt popover the
/// label broke into one letter per line and the time showed as an analog clock face.
public struct ScheduleDateForm: View {
    @Binding public var date: Date
    public let onCancel: () -> Void
    public let onSchedule: (Date) -> Void
    /// Injected so the past check and the quick picks follow the store's clock in tests.
    public let now: Date

    public init(
        date: Binding<Date>, now: Date = Date(), onCancel: @escaping () -> Void,
        onSchedule: @escaping (Date) -> Void
    ) {
        _date = date
        self.now = now
        self.onCancel = onCancel
        self.onSchedule = onSchedule
    }

    public var body: some View {
        let calendar = Calendar.current
        let isPast = ScheduleSuggestions.isInPast(date, now: now)
        VStack(alignment: .leading, spacing: 12) {
            Text("Ne zaman gönderilsin?")
                .font(.headline)

            HStack(spacing: 6) {
                ForEach(ScheduleSuggestions.suggestions(now: now, calendar: calendar), id: \.label) { suggestion in
                    Button(suggestion.label) { date = suggestion.date }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }

            // The calendar sets the day only; the time field below keeps the hour.
            DatePicker(
                "Gün",
                selection: Binding(
                    get: { date },
                    set: { date = ScheduleSuggestions.combine(day: $0, time: date, calendar: calendar) }),
                in: calendar.startOfDay(for: now)...,
                displayedComponents: .date
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            HStack {
                Text("Saat")
                Spacer()
                DatePicker(
                    "Saat",
                    selection: Binding(
                        get: { date },
                        set: { date = ScheduleSuggestions.combine(day: date, time: $0, calendar: calendar) }),
                    displayedComponents: .hourAndMinute
                )
                .datePickerStyle(.stepperField)
                .labelsHidden()
            }

            Text(isPast ? "Geçmiş bir zaman; ileri bir saat seç." : Formatting.scheduleSummary(date))
                .font(.callout)
                .foregroundStyle(isPast ? Color.red : Color.secondary)

            HStack {
                Spacer()
                Button("Vazgeç", action: onCancel)
                Button("Zamanla") { onSchedule(date) }
                    .buttonStyle(.glassProminent)
                    .disabled(isPast)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
