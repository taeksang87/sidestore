import SwiftUI

struct RouteEditView: View {
    @EnvironmentObject private var store: RouteStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Route
    @State private var texts: [DayType: String]
    @State private var selectedDay: DayType = .weekday
    @State private var expressText: String
    @State private var busText: String
    @State private var latitudeText: String
    @State private var longitudeText: String
    @State private var transferFareText: String

    @State private var genStart = RouteEditView.today(hour: 6, minute: 0)
    @State private var genEnd = RouteEditView.today(hour: 9, minute: 0)
    @State private var genInterval = 10
    @State private var confirmingDelete = false

    init(route: Route) {
        _draft = State(initialValue: route)
        _texts = State(initialValue: Dictionary(uniqueKeysWithValues: DayType.allCases.map {
            ($0, TimeText.format(route.times(for: $0)))
        }))
        _expressText = State(initialValue: route.expresses.map(\.line).joined(separator: "\n"))
        _busText = State(initialValue: route.busRoutes.joined(separator: " "))
        _latitudeText = State(initialValue: route.latitude.map { String($0) } ?? "")
        _longitudeText = State(initialValue: route.longitude.map { String($0) } ?? "")
        _transferFareText = State(initialValue: route.transferFare > 0 ? String(route.transferFare) : "")
    }

    private var isNew: Bool { !store.contains(draft) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("이름 (예: 동해선)", text: $draft.name)
                    TextField("타는 역/정류장 (예: 태화강)", text: $draft.stop)
                    TextField("내리는 역 (선택, 예: 센텀)", text: $draft.destination)
                    Picker("구분", selection: $draft.direction) {
                        ForEach(CommuteDirection.allCases) { d in
                            Text(d.title).tag(d)
                        }
                    }
                    Picker("수단", selection: $draft.transport) {
                        ForEach(Transport.allCases) { t in
                            Label(t.title, systemImage: t.symbol).tag(t)
                        }
                    }
                    Stepper("역까지 이동 \(draft.walkMinutes)분", value: $draft.walkMinutes, in: 0...90)
                    Stepper("탑승 시간 \(draft.rideMinutes)분", value: $draft.rideMinutes, in: 0...300)
                } header: {
                    Text("노선")
                } footer: {
                    Text("‘역까지 이동’은 출발해서 플랫폼에 서기까지 걸리는 시간이에요. 넣으면 언제 나가야 하는지 알려줘요. ‘탑승 시간’을 넣으면 도착 예상 시각을 보여줘요.")
                }

                Section {
                    Picker("요일", selection: $selectedDay) {
                        ForEach(DayType.allCases) { d in
                            Text(d.shortTitle).tag(d)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextEditor(text: textBinding(for: selectedDay))
                        .font(.body.monospacedDigit())
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .frame(minHeight: 150)

                    let parsed = TimeText.parse(texts[selectedDay] ?? "")
                    HStack {
                        Text("\(parsed.times.count)개 인식됨")
                        if !parsed.invalid.isEmpty {
                            Text("· 읽을 수 없음: \(parsed.invalid.prefix(3).joined(separator: ", "))")
                                .foregroundColor(.red)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                } header: {
                    Text("\(selectedDay.title) 시간표")
                } footer: {
                    Text("07:05 07:20 처럼 띄어쓰기·줄바꿈·쉼표로 구분해 입력하세요. 0705처럼 써도 돼요.")
                }

                Section {
                    DatePicker("첫차", selection: $genStart, displayedComponents: .hourAndMinute)
                    DatePicker("막차", selection: $genEnd, displayedComponents: .hourAndMinute)
                    Stepper("배차 간격 \(genInterval)분", value: $genInterval, in: 1...120)
                    Button("\(selectedDay.title) 시간표에 추가") {
                        let existing = TimeText.parse(texts[selectedDay] ?? "").times
                        let generated = TimeText.series(
                            start: TimeText.minutesOfDay(genStart),
                            end: TimeText.minutesOfDay(genEnd),
                            every: genInterval
                        )
                        texts[selectedDay] = TimeText.format(Array(Set(existing + generated)))
                    }
                } header: {
                    Text("일정한 간격으로 채우기")
                }

                Section("다른 요일에서 복사") {
                    ForEach(DayType.allCases.filter { $0 != selectedDay }) { other in
                        Button("\(other.title) 시간표 → \(selectedDay.title)") {
                            texts[selectedDay] = texts[other] ?? ""
                        }
                        .disabled((texts[other] ?? "").isEmpty)
                    }
                    Button("\(selectedDay.title) 시간표 비우기", role: .destructive) {
                        texts[selectedDay] = ""
                    }
                }

                Section {
                    TextEditor(text: $expressText)
                        .font(.callout.monospacedDigit())
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .frame(minHeight: 100)
                    let invalidLines = ExpressTrain.parse(expressText).invalidLines
                    if !invalidLines.isEmpty {
                        Text("읽을 수 없는 줄: \(invalidLines.prefix(2).joined(separator: " / "))")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    Stepper("환승 시간 \(draft.transferMinutes)분", value: $draft.transferMinutes, in: 0...120)
                    TextField("환승 추가 요금 (원)", text: $transferFareText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("직통열차 (ITX·KTX)")
                } footer: {
                    Text("한 줄에 하나씩: 종류 번호 출발 도착 도착역 요금\n예) KTX-이음 711 17:51 18:26 신해운대 8400\n도착역이 ‘내리는 역’과 다르면 환승 시간을 더해 최종 도착 시각을 보여줘요.")
                }

                Section {
                    TextField("위도 (예: 35.5384)", text: $latitudeText)
                        .keyboardType(.numbersAndPunctuation)
                    TextField("경도 (예: 129.3372)", text: $longitudeText)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("타는 역 좌표")
                } footer: {
                    Text("넣으면 출발 시각 날씨와 자전거 이용 가능 여부, 네이버지도 길찾기를 보여줘요.")
                }

                Section {
                    TextField("출발지 이름 (예: 명촌차고지)", text: $draft.busOrigin)
                    TextField("출발지 주소", text: $draft.busOriginAddress)
                    TextField("버스 번호 (띄어쓰기로 구분)", text: $busText)
                        .keyboardType(.numbersAndPunctuation)
                } header: {
                    Text("역까지 가는 버스")
                }

                if !isNew {
                    Section {
                        Button("노선 삭제", role: .destructive) {
                            confirmingDelete = true
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "노선 추가" : "노선 편집")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { save() }
                        .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("이 노선을 삭제할까요?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("삭제", role: .destructive) {
                    store.delete(draft)
                    dismiss()
                }
            }
        }
    }

    private func textBinding(for day: DayType) -> Binding<String> {
        Binding(
            get: { texts[day] ?? "" },
            set: { texts[day] = $0 }
        )
    }

    private func save() {
        var route = draft
        route.name = route.name.trimmingCharacters(in: .whitespaces)
        route.stop = route.stop.trimmingCharacters(in: .whitespaces)
        route.destination = route.destination.trimmingCharacters(in: .whitespaces)
        for day in DayType.allCases {
            route.setTimes(TimeText.parse(texts[day] ?? "").times, for: day)
        }
        route.expresses = ExpressTrain.parse(expressText).trains
        route.transferFare = Int(transferFareText.filter(\.isNumber)) ?? 0
        route.busRoutes = busText
            .components(separatedBy: CharacterSet(charactersIn: " ,\n\""))
            .filter { !$0.isEmpty }
        route.latitude = Double(latitudeText.trimmingCharacters(in: .whitespaces))
        route.longitude = Double(longitudeText.trimmingCharacters(in: .whitespaces))
        store.upsert(route)
        dismiss()
    }

    private static func today(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}
